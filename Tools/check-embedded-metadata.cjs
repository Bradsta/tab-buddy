// Compare original and enriched GP files using TabBuddy's exact playback runtime.
// Input: JSON array of {original, enriched} paths.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const alphaTab = require('../TabBuddy/GuitarProAssets/alphaTab.min.js');
const pairs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function musicalData(filename) {
    const settings = new alphaTab.Settings();
    const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(filename)), settings);
    const midi = new alphaTab.midi.MidiFile();
    new alphaTab.midi.MidiFileGenerator(score, settings, new alphaTab.midi.AlphaSynthMidiFileHandler(midi)).generate();
    return {tracks: score.tracks.length, bars: score.masterBars.length, midi: midi.events.map(event => JSON.stringify(event))};
}
for (const pair of pairs) {
    assert.deepEqual(musicalData(pair.enriched), musicalData(pair.original), pair.enriched);
}
console.log(`Verified ${pairs.length} original/enriched pairs: identical tracks, measures, and generated MIDI.`);
