const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const modulesRoot = process.env.CODEX_NODE_MODULES;
const playwright = modulesRoot
  ? require(path.join(modulesRoot, "playwright"))
  : require("playwright");

async function main() {
  const sourceDir = __dirname;
  const outputDir = path.resolve(sourceDir, "../mockups");
  fs.mkdirSync(outputDir, { recursive: true });

  const executablePath = process.env.CHROMIUM_EXECUTABLE;
  const browser = await playwright.chromium.launch({
    headless: true,
    ...(executablePath ? { executablePath } : {}),
  });
  const page = await browser.newPage({
    viewport: { width: 1760, height: 1160 },
    deviceScaleFactor: 1,
  });

  await page.goto(pathToFileURL(path.join(sourceDir, "mockups.html")).href, {
    waitUntil: "load",
  });
  await page.evaluate(async () => {
    if (document.fonts && document.fonts.ready) {
      await document.fonts.ready;
    }
  });

  const filenames = await page.locator("[data-file]").evaluateAll((boards) =>
    boards.map((board) => board.dataset.file).filter(Boolean)
  );
  for (const filename of filenames) {
    // Reload for every artboard. Reusing one composited page can leave text
    // from a previously hidden sidebar unrasterized in headless Chromium.
    await page.goto(pathToFileURL(path.join(sourceDir, "mockups.html")).href, {
      waitUntil: "load",
    });
    await page.evaluate(async () => {
      if (document.fonts && document.fonts.ready) {
        await document.fonts.ready;
      }
    });
    await page.evaluate((currentFilename) => {
      document.body.style.padding = "0";
      document.querySelectorAll("[data-file]").forEach((element) => {
        element.style.display = element.dataset.file === currentFilename ? "block" : "none";
        element.style.margin = "0";
      });
    }, filename);
    const isolatedBoard = page.locator(`[data-file="${filename}"]`);
    await isolatedBoard.scrollIntoViewIfNeeded();
    await page.waitForTimeout(250);
    // Warm every composited material layer before writing the final PNG.
    // Without this pass, headless Chrome can intermittently omit source-list
    // rows or toolbar glyphs that sit above backdrop-filter surfaces.
    await isolatedBoard.screenshot({ animations: "disabled" });
    await page.waitForTimeout(120);
    await isolatedBoard.screenshot({
      path: path.join(outputDir, filename),
      animations: "disabled",
    });
  }

  await browser.close();
  process.stdout.write(`Rendered ${filenames.length} mockups to ${outputDir}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
