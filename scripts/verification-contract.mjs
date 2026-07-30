function isTransparentColor(value) {
  if (typeof value !== "string") return false;
  const normalized = value.trim().toLowerCase();
  if (normalized === "transparent") return true;
  if (/^rgba\([^)]*,\s*0(?:\.0+)?\s*\)$/.test(normalized)) return true;
  return /^rgb\([^)]*\/\s*0(?:\.0+)?\s*\)$/.test(normalized);
}

export function removalSnapshotPasses(snapshot) {
  if (!snapshot || typeof snapshot !== "object") return false;
  return snapshot.installed === false &&
    Array.isArray(snapshot.themeClasses) && snapshot.themeClasses.length === 0 &&
    Array.isArray(snapshot.layoutClasses) && snapshot.layoutClasses.length === 0 &&
    snapshot.stylePresent === false &&
    snapshot.chromePresent === false &&
    snapshot.legacyControlsPresent === false &&
    snapshot.statePresent === false &&
    snapshot.disabledMarkerPresent === false &&
    snapshot.homeMarkerCount === 0 &&
    snapshot.shellMarkerCount === 0 &&
    snapshot.newTaskMarkerCount === 0 &&
    Array.isArray(snapshot.dreamInlineProperties) && snapshot.dreamInlineProperties.length === 0;
}

export function auxiliarySnapshotPasses(snapshot) {
  return removalSnapshotPasses(snapshot) &&
    snapshot.bodyBackgroundImage === "none" &&
    isTransparentColor(snapshot.bodyBackgroundColor);
}

export function mainSnapshotPasses(snapshot) {
  if (!snapshot || typeof snapshot !== "object") return false;
  return snapshot.installed === true &&
    snapshot.statePresent === true &&
    snapshot.stylePresent === true &&
    snapshot.chromePresent === true &&
    snapshot.legacyControlsPresent === false &&
    Array.isArray(snapshot.themes) && snapshot.themes.length > 0 &&
    snapshot.themes.includes(snapshot.theme) &&
    snapshot.themeClassActive === true &&
    ["banner", "fullscreen"].includes(snapshot.layout) &&
    snapshot.layoutClassActive === true &&
    snapshot.chromePointerEvents === "none" &&
    snapshot.homePresent === true &&
    snapshot.suggestionsPresent === true &&
    Boolean(snapshot.hero) &&
    Array.isArray(snapshot.cards) && snapshot.cards.length >= 2 && snapshot.cards.length <= 4 &&
    Boolean(snapshot.composer) &&
    Boolean(snapshot.sidebar);
}
