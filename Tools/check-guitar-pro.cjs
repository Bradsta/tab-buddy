// Validate real files using the exact runtime shipped in the app.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const alphaTab = require('../TabBuddy/GuitarProAssets/alphaTab.min.js');
const inputs = process.argv.slice(2);
if (!inputs.length) inputs.push(path.join(__dirname, '../TabBuddyTests/Fixtures/GuitarPro/practice.gp'));
for (const file of inputs) {
    const settings = new alphaTab.Settings();
    const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(file)), settings);
    assert.ok(score.tracks.length > 0, 'Must contain tracks');
    assert.ok(score.masterBars.length > 0, 'Must contain measures');
    const midi = new alphaTab.midi.MidiFile();
    const handler = new alphaTab.midi.AlphaSynthMidiFileHandler(midi);
    const generator = new alphaTab.midi.MidiFileGenerator(score, settings, handler);
    generator.generate();
    const first = generator.tickLookup.getMasterBar(score.masterBars[0]);
    const last = generator.tickLookup.getMasterBar(score.masterBars.at(-1));
    assert.ok(first.start >= 0 && last.end > first.start, 'Playback range must have positive duration');
    console.log(`${path.basename(file)}: ${score.title}; ${score.tracks.length} tracks; ${score.masterBars.length} bars; ${last.end} ticks`);
}
assert.throws(() => alphaTab.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array([1, 2, 3])));
