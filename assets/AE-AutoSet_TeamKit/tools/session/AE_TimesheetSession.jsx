#target aftereffects
#targetengine "AE_TimesheetSession"
#include "json2.jsxinc"
#include "AE_RemapExceedCore.jsxinc"
#include "AE_LayoutImport.jsxinc"
#include "AE_CellCanvas.jsxinc"
#include "AE_CameraLayout.jsxinc"
#include "AE_CharacterFX.jsxinc"
#include "AE_BatchSceneCore.jsxinc"
#include "AE_VerifySupport.jsxinc"

/* v1.13 apply/save path; no post-save reopen, structure review, or visual QA. */
(function () {
    var policy="saved_only_v1", launch=$.global.AE_TimesheetSessionLaunch, autoRun=false, selected=null, separate=false;
    if(launch && launch.manifest){
        selected=new File(launch.manifest);autoRun=launch.auto_run===true;separate=launch.separate===true;$.global.AE_TimesheetSessionLaunch=null;
        if(!selected.exists){throw new Error("Prepared launch manifest does not exist: "+selected.fsName);}
    }else{selected=File.openDialog("Select fresh session manifest.json","JSON:*.json");}
    if(!selected){return;}
    var V=TaskVerification, manifest=V.read(selected);
    if(manifest.version!==1 || !manifest.run_id || !manifest.jobs || !manifest.jobs.length || manifest.completion_policy!==policy){
        throw new Error("A fresh saved-only manifest is required; do not migrate an old running session.");
    }
    var existing=$.global.AE_TimesheetSession;
    if(existing && existing.window.visible){existing.window.close();}
    var resuming=new File(manifest.report).exists;
    var state={manifest:manifest,report:{version:1,run_id:manifest.run_id,completion_policy:policy,
        review_status:"skipped_by_user",results:[],complete:false}};
    if(resuming){state.report=V.read(new File(manifest.report));
        if(state.report.run_id!==manifest.run_id || state.report.completion_policy!==policy){throw new Error("Receipt belongs to another run or policy");}}
    function stamp(){return new Date().getTime();}
    function record(){V.write(new File(manifest.report),state.report);}
    function clean(){if(app.project && app.project.dirty){throw new Error("Unsaved project changes. Nothing was discarded.");}}
    function closeClean(){clean();if(app.project){app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);}}
    /* A separate instance exists only for this run: it holds no worker edits, so it closes itself when done. */
    function quitSeparate(){
        if(!separate){return;}
        try{if(app.project){app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);}}catch(ignored){}
        try{app.scheduleTask("app.quit();",1500,false);}catch(ignored){try{app.quit();}catch(ignored2){}}
    }
    function validateJob(job){
        var file=new File(job.project);
        if(job.template){
            var template=new File(job.template);
            if(!file.exists || !template.exists || !job.scene || !job.comp || !job.main_comp_output ||
                V.path(job.sceneFolder)!==V.path(file.parent) || job.scene!==file.parent.name ||
                V.path(file)===V.path(template) || (job.cut!==undefined && parseInt(job.cut,10)===0)){
                throw new Error("Invalid profiled scene project path or protected master");
            }
        }else{
            var match=/^DEMO_SC(\d+)$/i.exec(file.parent.name);
            if(!match || parseInt(match[1],10)===0 || file.name!==file.parent.name+".tk1.aep" ||
                V.path(job.sceneFolder)!==V.path(file.parent) || job.scene!==file.parent.name){throw new Error("Invalid scene project path or protected master");}
        }
        if(new File(job.baseline).exists){throw new Error("Previous execution baseline exists; do not reapply");}
    }
    function run(){
        clean();
        if(resuming || state.report.started_ms){throw new Error("This run already started; duplicate application refused");}
        for(var p=0;p<manifest.jobs.length;p++){validateJob(manifest.jobs[p]);}
        state.report.started_ms=stamp();runButton.enabled=false;record();
        for(var i=0;i<manifest.jobs.length;i++){
            var job=manifest.jobs[i], result={scene:job.scene,ok:false,started_ms:stamp(),
                review_status:"skipped_by_user",verification:{status:"skipped_by_user"},
                visual_complete:false,visual_required:[],visual_checks:[]};
            status.text=job.scene+" apply / save (no post-save review)";window.update();
            try{
                closeClean();app.open(new File(job.project));
                result.application=AE_BatchScene.applyCurrent(job);
                var savedFile=new File(job.project);
                if(!result.application.ok || !result.application.saved || !savedFile.exists || savedFile.length<=0 ||
                    !app.project.file || V.path(app.project.file)!==V.path(savedFile) ||
                    V.path(result.application.project)!==V.path(savedFile) || app.project.dirty){
                    throw new Error("Expected scene project was not saved successfully");
                }
                result.save_check={ok:true,project:savedFile.fsName,bytes:savedFile.length,dirty:false};
                result.saved_ms=stamp();result.ok=true;
            }catch(error){
                result.error=error.toString()+(error.line?" line="+error.line:"");
                if(app.project.file && V.path(app.project.file)===V.path(job.project)){app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);}
                var note=new File(job.sceneFolder+"/"+(job.apply_failure_note||"적용 실패.txt"));note.encoding="UTF-8";
                if(note.open("w")){note.write((job.auto_record_header||"AE_TimesheetAuto 자동 기록")+"\n"+result.error+"\n");note.close();}
            }
            result.finished_ms=stamp();state.report.results.push(result);record();
        }
        state.report.complete=true;state.report.finished_ms=stamp();state.report.ok=true;
        for(var r=0;r<state.report.results.length;r++){if(!state.report.results[r].ok){state.report.ok=false;}}
        record();status.text="Saved. Review skipped by request. AE remains open; run session finish.";
        quitSeparate();
    }
    function guarded(action){return function(){try{action();}catch(error){
        status.text=error.toString();
        if(separate && autoRun && !resuming){
            /* Nobody watches a separate instance: record the error instead of waiting on an alert, then quit. */
            state.report.error=error.toString();state.report.complete=true;state.report.ok=false;
            try{record();}catch(ignored){}
            quitSeparate();return;
        }
        alert(error.toString());}};}
    var window=new Window("palette","Timesheet Session - Save only",undefined,{resizeable:true});
    window.orientation="column";window.alignChildren=["fill","top"];
    var status=window.add("statictext",undefined,"Fresh manifest: "+manifest.run_id,{multiline:true});status.preferredSize=[510,40];
    var runButton=window.add("button",undefined,"Run fresh scenes");runButton.enabled=!resuming;
    window.add("statictext",undefined,"No frame approval, post-save reopen, or structural review.");
    runButton.onClick=guarded(run);state.window=window;$.global.AE_TimesheetSession=state;
    window.layout.layout(true);window.layout.resize();window.center();
    if(manifest.panel_location && manifest.panel_location.length===2){window.location=manifest.panel_location;}
    window.show();
    V.write(new File(manifest.report+".panel.json"),{visible:window.visible,bounds:String(window.bounds),location:String(window.location),size:String(window.size)});
    if(autoRun && !resuming){guarded(run)();}
}());
