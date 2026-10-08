// Native UI E2E checks for the installed Computer Use runner (cua_repl).
// Build: sh scripts/build-app.sh
// Fixture: python3 tests/e2e/projects-fixture.py setup
// Evaluate this file in cua_repl, then:
//   var checks = await createProjectsE2E(cua, {appPath, projectPath});
//   await checks.emptyAndAdd();
//   // fixture.py dirty
//   await checks.rejectDirtySwitch();
//   // fixture.py blocked, then clean
//   await checks.start();             // fixture.py running
//   await checks.stop();              // fixture.py stopped
//   await checks.persistence();
//   // fixture.py occupy (leave foreground server running in a separate terminal)
//   await checks.start();             // fixture.py running-collision
//   await checks.stop();              // fixture.py stopped; interrupt occupy
//   await checks.remove();
//   await checks.quit();             // fixture.py cleanup
// The fixture prints appPath and projectPath. No imports from Moth, synthetic
// callbacks, seeded project lists, fixed AX indices, or mocked servers are used.

async function createProjectsE2E(cua, {appPath, projectPath}) {
  let app = await cua.getApp(appPath);
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const snapshot = () => app.getAXState({disableDiffing: true, emit: false});
  const element = (state, pattern) => {
    const line = state.split('\n').find(line => pattern.test(line));
    assert(line, `Missing UI ${pattern}\n${state}`);
    assert(!line.includes('(disabled)'), `Disabled UI: ${line}`);
    return Number(line.trim().match(/^\d+/)[0]);
  };
  const click = async (pattern, options) => {
    await app.click(element(await snapshot(), pattern), options);
    return snapshot();
  };
  const waitFor = async (pattern) => {
    const deadline = Date.now() + 30_000;
    let state;
    do {
      state = await snapshot();
      if (pattern.test(state)) return state;
      // Observe the loading UI as well; CUA observations perform their own wait.
      await app.getScreenshot({emit: false});
    } while (Date.now() < deadline);
    throw new Error(`Timed out waiting for ${pattern}\n${state}`);
  };
  const projectRow = /button.*Moth's E2E project,/;
  const projects = /button Description: Projects,/;
  const close = /button Description: Close Projects,/;
  let launches = 0;

  return {
    async emptyAndAdd() {
      let state = await click(projects);
      assert(state.includes('ID: open-panel'), 'First Projects click must open the native folder chooser');
      state = await click(/button Cancel, ID: CancelButton/);
      assert(state.includes('Your projects, one click away'), 'Cancel must preserve the empty Projects panel');
      await click(close);
      state = await click(projects);
      assert(state.includes('ID: open-panel'), 'Cancel/reopen must open the chooser again');
      await app.pressKey('super+shift+g');
      state = await snapshot();
      await app.setValue(element(state, /text field.*ID: PathTextField/), projectPath);
      await snapshot();
      await app.pressKey('Return');
      state = await snapshot();
      assert(state.includes("Where:, Value: Moth's E2E project"), 'Picker must target the fixture directory');
      await click(/button Add Project, ID: OKButton/);
      state = await waitFor(/pop up button Description: Branch, Branch, Value: main/);
      assert(state.split('\n').filter(line => projectRow.test(line)).length === 1, 'Added folder must appear exactly once');
      assert(/button Start$/m.test(state), 'Added folder must be selected and ready to start');
      return 'PASS: empty click, cancel/reopen, real folder picker, add and branch discovery';
    },

    async rejectDirtySwitch() {
      await click(/pop up button Description: Branch,/);
      await click(/e2e-preview, ID: menuAction:/);
      await click(/button Start$/);
      const state = await waitFor(/Commit or stash your changes before switching branches/);
      assert(/Branch, Value: e2e-preview/.test(state), 'Selected target branch must remain available to retry');
      assert(!/button Stop$/m.test(state), 'Rejected switch must not start a server');
      return 'PASS: uncommitted work blocks branch switch and server launch';
    },

    async start() {
      await click(/button Start$/);
      const state = await waitFor(/heading Real dev server: e2e-preview/);
      assert(!state.includes('Description: Close Projects'), 'Ready server must dismiss Projects');
      assert(state.includes('button Description: New tab, Help: about:blank'), 'Original tab must survive launch');
      const tabs = state.split('\n').filter(line => /button Description: Moth E2E e2e-preview, Help: http:\/\/127\.0\.0\.1:/.test(line));
      assert(tabs.length === ++launches, 'Each launch must open exactly one new tab');
      assert(/HTML content Description: Moth E2E e2e-preview/.test(state), 'New tab must render the actual HTTP response');
      return 'PASS: selected branch starts a real server and opens one new tab';
    },

    async stop() {
      let state = await click(projects);
      assert(!state.includes('ID: open-panel'), 'Saved Projects must open the list, not the folder picker');
      state = await click(projectRow);
      assert(/pop up button \(disabled\) Description: Branch/.test(state), 'Running branch must be locked');
      await click(/button Stop$/);
      state = await waitFor(/button Start$/m);
      assert(!/button Stop$/m.test(state), 'Stopped project must be ready to restart');
      return 'PASS: running branch lock, Stop and restart controls';
    },

    async persistence() {
      await app.pressKey('super+q');
      for (let i = 0; i < 20; i++) {
        const apps = await cua.listApps({emit: false});
        if (!apps.some(item => item.id === 'dev.moth.e2e.projects' && item.isRunning)) break;
      }
      app = await cua.getApp(appPath);
      let state = await click(projects);
      assert(!state.includes('ID: open-panel'), 'Remembered projects must survive application restart');
      assert(state.split('\n').filter(line => projectRow.test(line)).length === 1, 'Restart must restore exactly one project');
      state = await click(projectRow);
      assert(/Branch, Value: e2e-preview/.test(state), 'Actual selected branch must survive restart');
      assert(/button Start$/m.test(state), 'Restart must not silently relaunch servers');
      return 'PASS: project and branch persist across a real application restart';
    },

    async remove() {
      await click(projectRow, {mouseButton: 'right'});
      const state = await click(/Remove from Projects/);
      assert(state.includes('Your projects, one click away'), 'Removing the last project must restore the empty state');
      assert(!state.includes('ID: open-panel'), 'Removal must not unexpectedly open a chooser');
      await click(close);
      const reopened = await click(projects);
      assert(reopened.includes('ID: open-panel'), 'The next Projects click must open the chooser after removing the last folder');
      await click(/button Cancel, ID: CancelButton/);
      return 'PASS: remove last folder and empty-state regression after removal';
    },

    async quit() { await app.pressKey('super+q'); }
  };
}
