// Builds the public DEMO master AEP from scratch: no footage, no production data.
// The camera rig uses the free F's Frame plug-in (F's Plugins, MIT) as its frame guide; install it first.
// Usage: AfterFX.exe -m -r make_demo_template.jsx   (writes DEMO_SC000.tk1.aep next to this script)
// The structure matches what AE AutoSet expects from a registered work:
//   00_rend/DEMO_SC000.tk1  -> 02_camera -> 01_Comp stage (cels on top, LO at the bottom, camera rig)
(function () {
    var here = new File($.fileName).parent;
    var target = new File(here.fsName + "/DEMO_SC000.tk1.aep");
    var done = new File(here.fsName + "/make_demo_template.done.txt");
    var STAGE_W = 2548, STAGE_H = 1580, OUT_W = 2048, OUT_H = 1080, FPS = 24, LONG = 600;

    function folder(name, parent) {
        var item = app.project.items.addFolder(name);
        if (parent) { item.parentFolder = parent; }
        return item;
    }
    // A guide label anchored at its left edge with fixed-width numbers, so it never shifts while playing.
    function guideText(comp, name, expression, position) {
        var layer = comp.layers.addText(name);
        layer.name = name;
        var text = layer.property("ADBE Text Properties").property("ADBE Text Document");
        var doc = text.value;
        doc.justification = ParagraphJustification.LEFT_JUSTIFY;
        doc.fontSize = 36;
        doc.applyFill = true; doc.fillColor = [0.1, 0.1, 0.1];
        doc.applyStroke = false;
        text.setValue(doc);
        text.expression = expression;
        layer.guideLayer = true;
        layer.property("ADBE Transform Group").property("ADBE Anchor Point").setValue([0, 0]);
        layer.property("ADBE Transform Group").property("ADBE Position").setValue(position);
        return layer;
    }
    function build() {
        app.beginSuppressDialogs();
        app.newProject();
        var rend = folder("00_rend"), comps = folder("10_comp");
        folder("20_CELL COMP");
        var source = folder("30_source");
        folder("01_LO", source); folder("02_CELL", source); folder("03_BG", source);

        // Working stage: the LO goes to the bottom, cels to the top.
        var stage = app.project.items.addComp("01_Comp stage", STAGE_W, STAGE_H, 1, LONG, FPS);
        stage.parentFolder = comps;
        stage.bgColor = [1, 1, 1];
        // 2D camera rig: a guide solid the size of the output frame, centred on the stage,
        // drawn by F's Frame (frame lines, safe frame, centre cross) at the output size.
        var camera = stage.layers.addSolid([1, 1, 1], "camera", OUT_W, OUT_H, 1, LONG);
        camera.guideLayer = true;
        camera.property("ADBE Transform Group").property("ADBE Position").setValue([STAGE_W / 2, STAGE_H / 2]);
        var frame = camera.property("ADBE Effect Parade").addProperty("F's Frame");
        frame.property("F's Frame-0001").setValue(OUT_W);
        frame.property("F's Frame-0002").setValue(OUT_H);
        guideText(stage, "TIME", 'function pad(n, w) { var s = String(n); while (s.length < w) { s = "0" + s; } return s; }\n' +
            'var fps = Math.round(1 / thisComp.frameDuration), f = Math.round(time * fps);\n' +
            '"frame " + pad(f + 1, 4) + "  (" + pad(Math.floor(f / fps), 2) + "+" + pad(f % fps + 1, 2) + ")";',
            [(STAGE_W - OUT_W) / 2 + 40, (STAGE_H - OUT_H) / 2 + 60]);

        // Output frame: the stage seen through the inverse of the camera rig.
        var output = app.project.items.addComp("02_camera", OUT_W, OUT_H, 1, LONG, FPS);
        output.parentFolder = comps;
        var view = output.layers.add(stage, LONG);
        var t = view.property("ADBE Transform Group"), ref = 'source.layer("camera")';
        t.property("ADBE Anchor Point").expression = ref + ".position";
        t.property("ADBE Position").expression = ref + ".anchorPoint";
        t.property("ADBE Scale").expression = "[10000/" + ref + ".scale[0],10000/" + ref + ".scale[1]]";
        t.property("ADBE Rotate Z").expression = "-" + ref + ".rotation";

        // Render comp, renamed per cut (DEMO_SC012.tk1 ...).
        var main = app.project.items.addComp("DEMO_SC000.tk1", OUT_W, OUT_H, 1, 6, FPS);
        main.parentFolder = rend;
        main.layers.add(output, LONG);
        guideText(main, "Title", "thisComp.name;", [40, OUT_H - 40]);

        app.project.save(target);
        app.endSuppressDialogs(false);
    }
    var log = "";
    try { build(); log = "ok " + target.fsName; } catch (error) { log = "error " + error.toString() + " line " + error.line; }
    done.encoding = "UTF-8"; done.open("w"); done.write(log); done.close();
    app.scheduleTask("app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES); app.quit();", 1500, false);
}());
