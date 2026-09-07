// Helpers for the persistent Computer Use CUA runtime. Pass a cua.getApp() handle
// for an isolated --in-memory-library --verification-pasteboard review build.
// The app must have an empty search field. This deliberately does NOT click it.
export async function verifyInitialSearchFocus(app) {
  await app.typeText("6 * 7");
  const state = await app.getAXState({ disableDiffing: true });
  if (!state.includes("Value: 6 * 7") || !state.includes("42, Calculator")) {
    throw new Error("Initial keyboard focus failed: typing did not produce the calculator result.");
  }
  return state;
}

export async function verifyEditorFocusRestoration(app) {
  await app.typeText("Verification");
  const state = await app.getAXState({ disableDiffing: true });
  if (!state.includes("Value: Verification")) {
    throw new Error("Search did not regain keyboard focus after the editor sheet closed.");
  }
  return state;
}

// Call from inside a library feature. No settling delay is allowed between Back and typing.
export async function verifyRapidBackTyping(app) {
  await app.pressKey("Escape");
  await app.typeText("search notes");
  const state = await app.getAXState({ disableDiffing: true });
  if (!state.includes("Value: search notes")) {
    throw new Error("Rapid input after Back lost characters.");
  }
  return state;
}

// Supply a descriptor reader for the dedicated private verification pasteboard.
// Run after an image fixture has been captured, without typing in search first.
export async function verifyEmptyClipboardImageCopy(app, describePasteboard) {
  const before = await app.getAXState({ disableDiffing: true });
  const search = before.split("\n").find((line) => line.includes("ID: launcher.search"));
  if (!search || search.includes("Value:") || !before.includes("Image ·")) {
    throw new Error("Expected an image result and an empty clipboard query.");
  }
  await app.pressKey("Return");
  const after = await app.getAXState({ disableDiffing: true });
  const clipboard = await describePasteboard();
  if (!after.includes("Copied to clipboard") || !clipboard.pngBytes ||
      !clipboard.types.includes("com.openray.generated")) {
    throw new Error("Return did not copy the selected image in its native format.");
  }
  return after;
}
