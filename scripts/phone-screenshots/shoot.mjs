// Screenshots of Flotilla on a real iPhone, through Appium. This script
// builds WebDriverAgent (the copy Appium's iOS driver ships) with your team's
// signing, runs it on the phone through xcodebuild, which reaches it over
// Wi-Fi too, and hands Appium its address. The first run builds for a few
// minutes; later ones reuse .wda-build/.
//
//   npm install                                   once, in this folder
//   node shoot.mjs                                the screen as it is now
//   node shoot.mjs bot "Architect"                that bot's Commands and Files
//   node shoot.mjs bot "Architect" Chat Tasks     ...or the panes named
//   node shoot.mjs panes [Commands Files ...]      the bot already open on the phone
//   BOTTOM=1 node shoot.mjs ...                    also the end of each pane's list
//   node shoot.mjs tour "Eval-Engineer"           every tab, a project, that bot's panes,
//                                                 a computer, the network, settings, switcher
//
// The phone must be unlocked, on the same Wi-Fi as this Mac (or on USB), and
// paired with Xcode. Found automatically, or set:
//   PHONE_UDID     the iPhone (default: the first paired iPhone that is available)
//   WDA_BUNDLE_ID  the runner's bundle id without ".xctrunner" (default: the
//                  WebDriverAgentRunner already on the phone, so it is replaced
//                  rather than a second one added)
// The app's team comes from Config/Local.xcconfig, its bundle id from there or,
// when Local.xcconfig does not set one, from Config/Signing.xcconfig.
// Screenshots land in shots/<time>/.

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { remote } from "webdriverio";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..");
const port = Number(process.env.APPIUM_PORT ?? 4724);
const [mode, ...rest] = process.argv.slice(2);
const botName = mode === "bot" ? rest[0] : undefined;
const asked = mode === "bot" ? rest.slice(1) : rest;
const panes = asked.length ? asked : ["Commands", "Files"];

function devicectlJSON(...args) {
  const out = join(here, ".devicectl.json");
  execFileSync("xcrun", ["devicectl", ...args, "--json-output", out, "--quiet"], { stdio: "ignore" });
  return JSON.parse(readFileSync(out, "utf8")).result;
}

function phoneUdid() {
  if (process.env.PHONE_UDID) return process.env.PHONE_UDID;
  const phone = devicectlJSON("list", "devices").devices.find(d =>
    d.hardwareProperties?.deviceType === "iPhone" && d.hardwareProperties?.reality === "physical" &&
    d.connectionProperties?.pairingState === "paired" && d.connectionProperties?.tunnelState !== "unavailable");
  if (!phone) throw new Error("No paired iPhone is available: unlock it, and keep it on this Mac's Wi-Fi or USB.");
  return phone.hardwareProperties.udid;
}

function wdaBundleId(udid) {
  if (process.env.WDA_BUNDLE_ID) return process.env.WDA_BUNDLE_ID;
  const apps = devicectlJSON("device", "info", "apps", "--device", udid).apps;
  const runner = apps.find(a => a.bundleIdentifier.endsWith("WebDriverAgentRunner.xctrunner"));
  if (!runner) throw new Error("No WebDriverAgentRunner on the phone: install it, or set WDA_BUNDLE_ID.");
  return runner.bundleIdentifier.replace(/\.xctrunner$/, "");
}

function localSetting(name) {
  for (const file of ["Local.xcconfig", "Signing.xcconfig"]) {
    const path = join(repo, "Config", file);
    if (!existsSync(path)) continue;
    const value = readFileSync(path, "utf8").match(new RegExp(`^${name}\\s*=\\s*(.+)$`, "m"))?.[1].trim();
    if (value) return value;
  }
}

const wdaProject = join(here, ".appium", "node_modules", "appium-xcuitest-driver", "node_modules",
                        "appium-webdriveragent", "WebDriverAgent.xcodeproj");
const wdaBuild = join(here, ".wda-build");

function wdaSettings(udid) {
  return ["-project", wdaProject, "-scheme", "WebDriverAgentRunner", "-destination", `id=${udid}`,
          "-derivedDataPath", wdaBuild, `DEVELOPMENT_TEAM=${localSetting("DEVELOPMENT_TEAM")}`,
          `PRODUCT_BUNDLE_IDENTIFIER=${wdaBundleId(udid)}`];
}

/// Builds WebDriverAgent once; the build is kept for later runs.
function buildWDA(udid) {
  const products = join(wdaBuild, "Build", "Products");
  if (existsSync(products) && readdirSync(products).some(f => f.endsWith(".xctestrun"))) return;
  console.log("Building WebDriverAgent (first run only)...");
  execFileSync("xcodebuild", ["build-for-testing", ...wdaSettings(udid), "-allowProvisioningUpdates",
                              "CODE_SIGN_IDENTITY=Apple Development"],
               { stdio: ["ignore", "ignore", "inherit"] });
}

/// Runs WebDriverAgent on the phone until killed; resolves with its address.
function startWDA(udid) {
  const run = spawn("xcodebuild", ["test-without-building", ...wdaSettings(udid)], { stdio: ["ignore", "pipe", "pipe"] });
  return new Promise((resolve, reject) => {
    let log = "";
    const timer = setTimeout(() => { run.kill(); reject(new Error("WebDriverAgent did not start on the phone.")); }, 180000);
    const read = chunk => {
      log += chunk;
      const url = log.match(/ServerURLHere->(\S+)<-/)?.[1];
      if (url) { clearTimeout(timer); resolve({ url, run }); }
    };
    run.stdout.on("data", read);
    run.stderr.on("data", read);
    run.on("exit", code => { clearTimeout(timer); reject(new Error(`WebDriverAgent stopped (xcodebuild ${code}).`)); });
  });
}

async function startAppium() {
  const server = spawn(join(here, "node_modules", ".bin", "appium"), ["--port", String(port), "--log-level", "error"], {
    env: { ...process.env, APPIUM_HOME: join(here, ".appium") },
    stdio: ["ignore", "inherit", "inherit"],
  });
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/status`)).ok) return server;
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  server.kill();
  throw new Error("Appium did not start.");
}

const pause = ms => new Promise(r => setTimeout(r, ms));

/// Taps the first element whose label matches, scrolling it into view if needed.
async function tap(driver, predicate, what) {
  const element = await driver.$(`-ios predicate string:${predicate}`);
  if (!(await element.isExisting())) throw new Error(`Could not find ${what} on screen.`);
  if (!(await element.isDisplayed())) {
    await driver.execute("mobile: scrollToElement", { elementId: element.elementId }).catch(() => {});
  }
  await element.click();
}

const q = s => s.replace(/"/g, '\\"');
const button = label => `type == "XCUIElementTypeButton" AND label == "${q(label)}"`;

/// Closes a sheet or menu: its own close button if it has one, else a swipe down.
async function dismiss(driver) {
  for (const label of ["Done", "Cancel", "Close"]) {
    const el = await driver.$(`-ios predicate string:${button(label)}`);
    if (await el.isExisting() && await el.isDisplayed()) { await el.click(); await pause(1200); return; }
  }
  // The status bar: closes a menu, and touches nothing in the app.
  await driver.execute("mobile: tap", { x: 200, y: 8 }).catch(() => {});
  await pause(800);
  const sheet = await driver.$('-ios predicate string:type == "XCUIElementTypeSheet" OR type == "XCUIElementTypeAlert"');
  if (await sheet.isExisting()) {
    await driver.execute("mobile: swipe", { direction: "down" }).catch(() => {});
    await pause(1200);
  }
}

async function back(driver) {
  await driver.back().catch(() => {});
  await pause(1500);
}

/// Walks the whole app, one screenshot per stop; a stop that cannot be
/// reached is skipped with a note, so one missing label does not end the tour.
async function tour(driver, botName, shoot) {
  let n = 0;
  const snap = async name => shoot(`${String(++n).padStart(2, "0")}-${name}`);
  const step = async (what, fn) => {
    try { await fn(); } catch (error) { console.log(`  skipped ${what}: ${error.message}`); }
  };
  const scrollShots = async (name, times) => {
    for (let i = 1; i <= times; i++) {
      await driver.execute("mobile: swipe", { direction: "up" }).catch(() => {});
      await pause(900);
      await snap(`${name}-scrolled-${i}`);
    }
  };

  // Start from the top level, where the tab bar shows.
  for (let i = 0; i < 5; i++) {
    if (await (await driver.$(`-ios predicate string:${button("Decisions")}`)).isExisting()) break;
    await back(driver);
  }
  // The first match that is on screen, tapped by position: some controls
  // (the floating tab bar, toolbar buttons) report themselves as hidden.
  const firstShown = async (predicate, what) => {
    for (const el of await driver.$$(`-ios predicate string:${predicate}`)) {
      const r = await driver.getElementRect(el.elementId).catch(() => null);
      if (r && r.width > 0 && r.height > 0 && r.y >= 0 && r.y + r.height <= 960) {
        return { click: () => driver.execute("mobile: tap", { x: r.x + r.width / 2, y: r.y + r.height / 2 }) };
      }
    }
    throw new Error(`no ${what} on screen`);
  };
  // Other tabs stay alive offscreen: tap the tab bar's own, visible button.
  const tab = async label => {
    // The floating tab bar reports its buttons as hidden; the lowest one on
    // screen is the tab bar's.
    let best;
    for (const el of await driver.$$(`-ios predicate string:${button(label)}`)) {
      const r = await driver.getElementRect(el.elementId).catch(() => null);
      if (r && r.width > 0 && (!best || r.y > best.y)) best = r;
    }
    if (!best) throw new Error(`no ${label} tab`);
    await driver.execute("mobile: tap", { x: best.x + best.width / 2, y: best.y + best.height / 2 });
    await pause(2000);
  };
  await step("Home", async () => { await tab("Home"); await pause(3000); await snap("home"); await scrollShots("home", 1); });
  await step("Settings", async () => { await (await firstShown(button("Settings"), "Settings")).click(); await pause(1500); await snap("settings"); await dismiss(driver); });
  await step("Bots", async () => { await tab("Bots"); await pause(2000); await snap("bots"); await scrollShots("bots", 1); });
  await step("Create", async () => { await (await firstShown('label == "Create"', "Create")).click(); await pause(1200); await snap("create-menu"); await dismiss(driver); });
  await step("project", async () => {
    await driver.execute("mobile: swipe", { direction: "down" }).catch(() => {});
    await (await firstShown('label CONTAINS "Open the project"', "project header")).click();
    await pause(2500); await snap("project"); await scrollShots("project", 1); await back(driver);
  });
  if (botName) {
    await step("bot", async () => {
      await tab("Bots");
      await (await firstShown(`label BEGINSWITH "${q(botName)}"`, botName)).click(); await pause(2500);
      for (const pane of ["Chat", "Work", "Files", "More", "Activity", "Messages"]) {
        await step(pane, async () => {
          const el = await firstShown(button(pane), pane).catch(() => null);
          if (!el) return;
          await el.click(); await pause(3500); await snap(`bot-${pane.toLowerCase()}`);
          if (pane === "Work" || pane === "More") await scrollShots(`bot-${pane.toLowerCase()}`, 1);
        });
      }
      await back(driver);
    });
  }
  await step("Decisions", async () => { await tab("Decisions"); await pause(2500); await snap("decisions"); await scrollShots("decisions", 1); });
  await step("Files", async () => {
    await tab("Files"); await pause(2500); await snap("files");
    await step("a report", async () => {
      const cell = await driver.$('-ios predicate string:type == "XCUIElementTypeCell"');
      await cell.click(); await pause(3000); await snap("report"); await back(driver);
    });
  });
  await step("Computers", async () => {
    await tab("Computers"); await pause(2500); await snap("computers");
    await step("a computer", async () => {
      await (await firstShown('label BEGINSWITH "Windows" OR label BEGINSWITH "Mac"', "a computer")).click(); await pause(3500); await snap("computer"); await scrollShots("computer", 3); await back(driver);
    });
    await step("network", async () => {
      await (await firstShown('label BEGINSWITH "Links between computers"', "Links between computers")).click();
      await pause(3000); await snap("network"); await back(driver);
    });
  });
  await step("back home", async () => { await tab("Home"); });
  await step("computer switcher", async () => {
    await (await firstShown('label BEGINSWITH "Computer: "', "the computer switcher")).click();
    await pause(1200); await snap("computer-switcher"); await dismiss(driver);
  });

}

async function main() {
  const udid = phoneUdid();
  const out = join(here, "shots", new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19));
  mkdirSync(out, { recursive: true });

  buildWDA(udid);
  const wda = await startWDA(udid);
  const server = await startAppium();
  let driver;
  try {
    driver = await remote({
      hostname: "127.0.0.1", port, path: "/", logLevel: "error",
      capabilities: {
        platformName: "iOS",
        "appium:automationName": "XCUITest",
        "appium:udid": udid,
        "appium:bundleId": localSetting("PRODUCT_BUNDLE_IDENTIFIER"),
        "appium:webDriverAgentUrl": wda.url,
        "appium:noReset": true,
        "appium:newCommandTimeout": 300,
      },
    });

    const shoot = async name => {
      const file = join(out, `${name}.png`);
      await driver.saveScreenshot(file);
      console.log(`  ${file}`);
    };

    if (mode === "tour") {
      await tour(driver, rest[0], shoot);
      return;
    }
    if (mode !== "bot" && mode !== "panes") {
      await shoot("screen");
      writeFileSync(join(out, "screen.xml"), await driver.getPageSource());
      return;
    }
    if (mode === "bot") {
      if (!botName) throw new Error('Name the bot: node shoot.mjs bot "Architect"');
      await tap(driver, 'type == "XCUIElementTypeButton" AND label == "Bots"', "the Bots tab");
      await pause(1500);
      await tap(driver, `label BEGINSWITH "${botName.replace(/"/g, '\\"')}"`, `the bot "${botName}"`);
      await pause(2500);
    }
    const prefix = botName ?? "bot";
    for (const pane of panes) {
      await tap(driver, `type == "XCUIElementTypeButton" AND label == "${pane}"`, `the ${pane} pane`);
      // Give the pane its first page over the network.
      await pause(3500);
      await shoot(`${prefix}-${pane}`.replace(/[^\w.-]+/g, "_"));
      // The page source too, to read labels and sizes without guessing.
      writeFileSync(join(out, `${prefix}-${pane}.xml`.replace(/[^\w.-]+/g, "_")), await driver.getPageSource());
      if (process.env.BOTTOM) {
        // The end of the list as well.
        for (let i = 0; i < 12; i++) await driver.execute("mobile: swipe", { direction: "up" }).catch(() => {});
        await pause(1000);
        await shoot(`${prefix}-${pane}-bottom`.replace(/[^\w.-]+/g, "_"));
      }
    }
  } finally {
    await driver?.deleteSession().catch(() => {});
    server.kill();
    wda.run.kill();
  }
}

main().catch(error => {
  console.error(error.message ?? error);
  process.exit(1);
});
