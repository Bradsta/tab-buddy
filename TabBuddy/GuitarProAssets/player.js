/* Offline score engine. All controls are shared native SwiftUI components. */
'use strict';
(async () => {
    const status = document.getElementById('status');
    let api, score, runtimeURL, disposed = false, previousTick = 0, lastUpdate = 0;
    let options = { speed: 1, track: 0, solo: false, sound: true, metronome: false,
        zoom: 1, notation: 'original', follow: 'follow', smoothSpeed: 0, smoothLoop: false, loop: false, start: 0, end: 1 };
    const state = { ready: false, playing: false, bar: 0, time: 0, total: 0,
        tempo: 120, beats: 4, tracks: [], loopPass: 0, error: null };
    const send = () => {
        window.tabBuddyPlayer.state = { ...state, options: { ...options } };
        window.webkit?.messageHandlers?.player?.postMessage(window.tabBuddyPlayer.state);
    };
    const fail = error => {
        state.ready = false;
        state.error = 'Could not open this Guitar Pro file. It may be damaged or unsupported.';
        status.textContent = state.error;
        if (api) api.pause();
        send();
    };
    const clamp = (value, min, max) => Math.max(min, Math.min(max, Number(value) || 0));
    const applyLoop = () => {
        if (!api.tickCache || !score) return;
        let start = Math.floor(clamp(options.start, 0, score.masterBars.length - 1));
        let end = Math.floor(clamp(options.end, 0, score.masterBars.length - 1));
        if (start > end) [start, end] = [end, start];
        options.start = start; options.end = end;
        previousTick = 0;
        if (options.loop) {
            api.playbackRange = {
                startTick: api.tickCache.getMasterBar(score.masterBars[start]).start,
                endTick: api.tickCache.getMasterBar(score.masterBars[end]).end
            };
            api.isLooping = true;
        } else { api.isLooping = false; api.playbackRange = null; }
    };
    const configure = values => {
        const old = { ...options };
        options = { ...options, ...values };
        options.speed = clamp(options.speed, 0.25, 1.5);
        options.zoom = clamp(options.zoom, 0.8, 1.8);
        options.smoothSpeed = clamp(options.smoothSpeed, 0, 40);
        updateScrollClock();
        if (!score) return;
        options.track = Math.floor(clamp(options.track, 0, score.tracks.length - 1));
        api.playbackSpeed = options.speed;
        api.metronomeVolume = options.metronome ? 1 : 0;
        api.changeTrackMute(score.tracks, !options.sound);
        api.changeTrackSolo(score.tracks, false);
        if (options.solo) api.changeTrackSolo([score.tracks[options.track]], true);
        if (old.track !== options.track || old.zoom !== options.zoom || old.notation !== options.notation || old.follow !== options.follow) {
            api.settings.display.scale = options.zoom;
            const hasStrings = score.tracks[options.track].staves.some(s => s.stringTuning.tunings.length > 0);
            api.settings.display.staveProfile = !hasStrings ? alphaTab.StaveProfile.Score :
                options.notation === 'original' ? alphaTab.StaveProfile.Default :
                options.notation === 'staffOnly' ? alphaTab.StaveProfile.Score :
                options.notation === 'tabAndStaff' ? alphaTab.StaveProfile.ScoreTab : alphaTab.StaveProfile.Tab;
            api.settings.player.scrollMode = ['off', 'smooth'].includes(options.follow) ? alphaTab.ScrollMode.Off :
                options.follow === 'line' ? alphaTab.ScrollMode.OffScreen : alphaTab.ScrollMode.Continuous;
            api.updateSettings();
            api.renderTracks([score.tracks[options.track]]);
        }
        if (old.loop !== options.loop || old.start !== options.start || old.end !== options.end) applyLoop();
        send();
    };
    const seek = bar => {
        if (!state.ready) return;
        bar = Math.floor(clamp(bar, 0, score.masterBars.length - 1));
        previousTick = 0;
        api.tickPosition = api.tickCache.getMasterBar(score.masterBars[bar]).start;
        state.bar = bar;
        state.beats = score.masterBars[bar].timeSignatureNumerator;
        send();
    };
    const scroll = document.getElementById('score-scroll');
    let scrollFrame = 0, scrollTime = 0, scrollResidual = 0, touching = false;
    scroll.addEventListener('pointerdown', () => { touching = true; });
    window.addEventListener('pointerup', () => { touching = false; scrollTime = 0; });
    window.addEventListener('pointercancel', () => { touching = false; scrollTime = 0; });
    const smoothScroll = time => {
        scrollFrame = 0;
        if (!shouldScroll()) return;
        if (scrollTime && !touching && !document.hidden && options.follow === 'smooth' && options.smoothSpeed > 0) {
            const bottom = Math.max(0, scroll.scrollHeight - scroll.clientHeight);
            scrollResidual += options.smoothSpeed * Math.min(0.05, (time - scrollTime) / 1000);
            const step = Math.floor(scrollResidual);
            scrollResidual -= step;
            const next = scroll.scrollTop + step;
            scroll.scrollTop = options.smoothLoop && next > bottom ? 0 : Math.min(bottom, next);
        }
        scrollTime = time;
        scrollFrame = requestAnimationFrame(smoothScroll);
    };
    const shouldScroll = () => !disposed && state.ready && !document.hidden &&
        options.follow === 'smooth' && options.smoothSpeed > 0;
    const updateScrollClock = () => {
        if (!shouldScroll()) {
            cancelAnimationFrame(scrollFrame);
            scrollFrame = 0;
            scrollTime = 0;
            scrollResidual = 0;
        } else if (!scrollFrame) {
            scrollFrame = requestAnimationFrame(smoothScroll);
        }
    };
    window.tabBuddyPlayer = { state, configure, seek,
        scrollToTop: () => { scroll.scrollTop = 0; },
        play: () => { if (state.ready) api.play(); }, pause: () => api?.pause() };
    window.pausePlayback = () => api?.pause();
    window.disposePlayer = () => {
        disposed = true;
        updateScrollClock();
        api?.destroy();
        if (runtimeURL) URL.revokeObjectURL(runtimeURL);
    };
    try {
        const runtime = await new Promise((resolve, reject) => {
            const request = new XMLHttpRequest();
            request.open('GET', 'alphaTab.min.js');
            request.onload = () => request.responseText ? resolve(request.responseText) : reject(new Error('Player runtime unavailable.'));
            request.onerror = () => reject(new Error('Player runtime unavailable.'));
            request.send();
        });
        if (disposed) return;
        runtimeURL = URL.createObjectURL(new Blob([runtime], { type: 'text/javascript' }));
        api = new alphaTab.AlphaTabApi(document.getElementById('score'), {
            core: { useWorkers: false, scriptFile: runtimeURL, fontDirectory: 'font/' },
            display: { scale: 1, staveProfile: alphaTab.StaveProfile.Default },
            notation: { elements: { scoreTitle: false, scoreSubTitle: false, scoreArtist: false,
                scoreAlbum: false, scoreWords: false, scoreMusic: false, scoreWordsAndMusic: false,
                guitarTuning: false } },
            player: { playerMode: alphaTab.PlayerMode.EnabledSynthesizer,
                outputMode: alphaTab.PlayerOutputMode.WebAudioScriptProcessor,
                soundFont: 'soundfont/sonivox.sf2', scrollElement: document.getElementById('score-scroll'),
                enableCursor: true, enableUserInteraction: false }
        });
        const appearance = window.matchMedia('(prefers-color-scheme: dark)');
        const updateAppearance = () => {
            const dark = appearance.matches;
            const color = (r, g, b) => new alphaTab.model.Color(r, g, b);
            const resources = api.settings.display.resources;
            resources.mainGlyphColor = resources.scoreInfoColor = dark ? color(244, 235, 226) : color(35, 28, 24);
            resources.staffLineColor = dark ? color(117, 105, 96) : color(178, 168, 158);
            resources.barSeparatorColor = resources.secondaryGlyphColor = dark ? color(182, 169, 157) : color(96, 86, 79);
            resources.barNumberColor = dark ? color(240, 126, 121) : color(194, 77, 79);
            api.updateSettings();
            if (score) api.render();
        };
        updateAppearance();
        appearance.addEventListener('change', updateAppearance);
        api.error.on(fail);
        let pointerStart = null, moved = false;
        const scoreElement = document.getElementById('score');
        scoreElement.addEventListener('pointerdown', event => {
            pointerStart = { x: event.clientX, y: event.clientY }; moved = false;
        }, true);
        scoreElement.addEventListener('pointermove', event => {
            if (pointerStart && Math.hypot(event.clientX - pointerStart.x, event.clientY - pointerStart.y) > 8) moved = true;
        }, true);
        scoreElement.addEventListener('pointercancel', () => { moved = true; }, true);
        api.beatMouseUp.on(beat => { if (!moved) seek(beat.voice.bar.masterBar.index); });
        api.scoreLoaded.on(value => {
            score = value;
            state.total = score.masterBars.length;
            state.tempo = score.tempo || 120;
            state.beats = score.masterBars[0]?.timeSignatureNumerator || 4;
            state.composer = score.music || '';
            state.artist = score.artist || '';
            state.copyright = score.copyright || '';
            state.notices = score.notices || '';
            state.title = score.title || '';
            state.arranger = score.tab || '';
            state.collection = score.album || '';
            state.tracks = score.tracks.map(t => ({ id: t.index, name: t.name || `Track ${t.index + 1}`,
                program: t.playbackInfo.program, percussion: t.staves.some(s => s.isPercussion),
                tuning: t.staves[0]?.stringTuning?.tunings?.map(n => ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'][n % 12]).reverse().join(' ') || t.staves[0]?.stringTuning?.name || '', capo: t.staves[0]?.capo || 0 }));
            status.textContent = 'Preparing sound…';
            configure(options);
            send();
        });
        api.playerReady.on(() => {
            state.ready = true; status.textContent = '';
            applyLoop(); updateScrollClock(); send();
        });
        api.playerStateChanged.on(e => { state.playing = e.state === 1; send(); });
        api.playedBeatChanged.on(beat => {
            state.bar = beat.voice.bar.masterBar.index;
            state.beats = beat.voice.bar.masterBar.timeSignatureNumerator;
        });
        api.playerPositionChanged.on(e => {
            if (state.playing && options.loop && e.currentTick < previousTick) state.loopPass++;
            previousTick = e.currentTick;
            state.time = e.currentTime / 1000;
            const now = Date.now();
            if (now - lastUpdate > 150) { lastUpdate = now; send(); }
        });
        document.addEventListener('visibilitychange', () => {
            if (document.hidden) api.pause();
            updateScrollClock();
        });
        api.load('score');
    } catch (error) { fail(error); }
})();
