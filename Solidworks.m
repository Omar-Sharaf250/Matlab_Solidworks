classdef Solidworks < handle
    properties (Access = private)
        App
        Active_Doc
        Active_Doc_Sim
        Active_Study
        Active_Study_idx
        Rebuild_Flag
        RootFolder
        BridgeFolder
        TemplateFolder
        IsSketchActive = false
        simPath
        SimApp
        CosmosEngine
    end
    methods (Access = private)

        function RunBridge(obj)
            invoke(obj.App,...
                'RunMacro',...
                fullfile(obj.BridgeFolder,"Bridge.swp"),...
                'Bridge1',...
                'Main');
        end
        function LoadSimulation(obj)
            invoke(obj.App, 'LoadAddIn', obj.simPath);
            pause(3);
            disp('Simulation Add-in Loaded!');
        end
        function Select(obj,name,type)
            CommandFile = fullfile(obj.BridgeFolder,"Command.txt");
            fid = fopen(CommandFile,'w');
            fprintf(fid,"COMMAND=SELECT\n");
            fprintf(fid,"NAME=%s\n",name);
            fprintf(fid,"TYPE=%s\n",type);
            fclose(fid);
            obj.RunBridge
        end
        function SyncActiveDoc(obj, Part)
            obj.Active_Doc = Part;
            obj.Active_Doc_Sim = get(obj.CosmosEngine, 'ActiveDoc');
        end
    end
    methods
        function obj = Solidworks(Visible)
            % 1. Start Solidworks Server
            obj.App = actxserver('SldWorks.Application');
            if Visible
                set(obj.App,'Visible',true);
            else
                set(obj.App,'Visible',false);
            end
            invoke(obj.App, 'SetUserPreferenceIntegerValue', 73, 2);
            try
                swExePath = invoke(obj.App, 'GetExecutablePath');
                obj.simPath = fullfile(swExePath, 'Simulation', 'cosworks.dll');
                fprintf('Successfully resolved Cosmos DLL: %s\n', obj.simPath);
            catch
                % Emergency backup if COM interface is restricted on a system
                obj.simPath = 'C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\Simulation\cosworks.dll';
                warning('Could not query SolidWorks for path. Falling back to default C: drive installation.');
            end

            % 2. Resolve relative Bridge Folders
            classFolder = (mfilename('fullpath'));
            obj.RootFolder = fileparts(classFolder);
            obj.BridgeFolder = fullfile(obj.RootFolder,...
                "Bridge");
            obj.TemplateFolder = fullfile(obj.BridgeFolder,"templates");

            % 3. Load Simulation using the newly resolved dynamic path
            obj.LoadSimulation()
            obj.SimApp = invoke(obj.App, 'GetAddInObject', 'SldWorks.Simulation');
            obj.CosmosEngine = get(obj.SimApp, 'CosmosWorks');
        end
        function  SelectStudy(obj, studyName)
            simDoc = obj.Active_Doc_Sim;
            studyMgr = get(simDoc, 'StudyManager');
            numStudies = get(studyMgr, 'StudyCount');
            for i = 0:(numStudies - 1)
                tempStudy = invoke(studyMgr, 'GetStudy', int32(i));
                tempName = get(tempStudy, 'Name');
                if strcmp(tempName, char(studyName))
                    set(studyMgr, 'ActiveStudy', int32(i));
                    fprintf('Success: Study "%s" is now active (Index: %d)!\n', studyName, i);
                    obj.Active_Study_idx = i;
                    obj.Active_Study = invoke(studyMgr,'GetStudy',i);
                    return;
                end
            end
            error('Could not find a simulation study named "%s" to select.', studyName);
        end
        function SetMaterial(obj, targetBodyName, materialName)
            studyIdx = obj.Active_Study_idx;
            obj.Select(targetBodyName, 'SOLIDBODY');
            CommandFile = fullfile(obj.BridgeFolder, "Command.txt");
            fid = fopen(CommandFile, 'w');
            fprintf(fid, 'COMMAND=SET_MATERIAL\n');
            fprintf(fid, 'STUDY_INDEX=%d\n', studyIdx);
            fprintf(fid, 'MATERIAL_NAME=%s\n', char(materialName));
            fclose(fid);
            obj.RunBridge();
            fprintf('Sent command to VBA to apply "%s" to "%s" on Study Index %d\n', materialName, targetBodyName, studyIdx);
        end
        function OpenDoc(obj, filePath)
            swDocSpec = invoke(obj.App, 'GetOpenDocSpec', filePath);
            Part = invoke(obj.App, 'OpenDoc7', swDocSpec);
            if isempty(Part)
                error('Failed to open document: %s', filePath);
            else
                obj.SyncActiveDoc(Part)
                fprintf('Success: Loaded -> %s\n', filePath);
            end
        end
        function rebuild_success = ChangeParameters(obj,ParamNames,ParamValues, return_old_values_if_failed)
            if nargin < 4 || isempty(axisComp)
                return_old_values_if_failed = 0;
            end
            ParamNames = cellstr(ParamNames);
            if ~(length(ParamNames) == length(ParamValues))
                fprintf("Provide all parameter names/values please")
                return
            end
            OldValues = zeros(1,length(ParamValues));
            for i = 1:length(ParamValues)
                Param = invoke(obj.Active_Doc,'Parameter',ParamNames{i});
                OldValues(i) = get(Param,'SystemValue');
                set(Param, 'SystemValue', ParamValues(i));
            end
            rebuild_success = invoke(obj.Active_Doc, 'EditRebuild3');
            obj.Rebuild_Flag = rebuild_success;
            if rebuild_success
                fprintf("Rebuild succeeded\n")
                return
            else
                if return_old_values_if_failed
                    fprintf("Rebuild failed geometry can't be satisfied\n")
                    fprintf("Returning old params...\n")
                    obj.ChangeParameters(ParamNames,OldValues)
                end
                fprintf("Rebuild failed geometry can't be satisfied\n")
            end
        end
        function RunStudy(obj)
            invoke(obj.Active_Study,'MeshAndRun');
            fprintf("Study has been successfully run\n")
        end
        function maxResult = GET_MINMAX_DISPLACEMENT(obj, axisComp)
            % GET_MINMAX_DISPLACEMENT: Fetch max displacement.
            % Defaults to "RES" (Resultant) if no axis is provided.
            cwResult = get(obj.Active_Study, 'Results');
            if (isempty(cwResult) || ~obj.Rebuild_Flag)
                maxResult = NaN;
                return; % The object doesn't exist! Abort the iteration before Error -91 happens!
            end
            if nargin < 2 || isempty(axisComp)
                axisComp = 'RES';
            end

            cmdFile = fullfile(obj.BridgeFolder, "Command.txt");
            resFile = fullfile(obj.BridgeFolder, "result.txt");

            % 1. Clean up stale results
            if exist(resFile, 'file')
                delete(resFile);
            end

            % 2. Write commands to Command.txt
            fid = fopen(cmdFile, 'w');
            if fid == -1
                error('Could not write to: %s', cmdFile);
            end
            fprintf(fid, 'COMMAND=GET_MINMAX_DISPLACEMENT\n');
            fprintf(fid, 'STUDY_INDEX=%d\n', obj.Active_Study_idx);
            fprintf(fid, 'AXIS=%s\n', upper(axisComp));
            fclose(fid);

            % 3. Run the bridge macro
            obj.RunBridge();

            % 4. Wait slightly and read the output file
            pause(5/1000);
            if exist(resFile, 'file')
                fid = fopen(resFile, 'r');
                maxResult = fscanf(fid, '%f');
                fclose(fid);
                fprintf('Successfully retrieved GET_MINMAX_DISPLACEMENT [%s]: %e\n', upper(axisComp), maxResult);
            else
                error('VBA execution completed but "result.txt" was missing in Bridge folder.');
            end
        end
        function maxResult = GET_MINMAX_STRESS(obj, axisComp)
            % GET_MINMAX_STRESS: Fetch max stress.
            % Defaults to "VON" (von Mises) if no axis is provided.
            cwResult = get(obj.Active_Study, 'Results');
            if (isempty(cwResult) || ~obj.Rebuild_Flag)
                maxResult = NaN;
                return; % The object doesn't exist! Abort the iteration before Error -91 happens!
            end
            if nargin < 2 || isempty(axisComp)
                axisComp = 'VON';
            end

            cmdFile = fullfile(obj.BridgeFolder, "Command.txt");
            resFile = fullfile(obj.BridgeFolder, "result.txt");

            % 1. Clean up stale results
            if exist(resFile, 'file')
                delete(resFile);
            end

            % 2. Write commands to Command.txt
            fid = fopen(cmdFile, 'w');
            if fid == -1
                error('Could not write to: %s', cmdFile);
            end
            fprintf(fid, 'COMMAND=GET_MINMAX_STRESS\n');
            fprintf(fid, 'STUDY_INDEX=%d\n', obj.Active_Study_idx);
            fprintf(fid, 'AXIS=%s\n', upper(axisComp));
            fclose(fid);

            % 3. Run the bridge macro
            obj.RunBridge();

            % 4. Wait slightly and read the output file
            pause(5/1000);
            if exist(resFile, 'file')
                fid = fopen(resFile, 'r');
                maxResult = fscanf(fid, '%f');
                fclose(fid);
                fprintf('Successfully retrieved GET_MINMAX_STRESS [%s]: %e\n', upper(axisComp), maxResult);
            else
                error('VBA execution completed but "result.txt" was missing in Bridge folder.');
            end
        end
        function mass = GetMass(obj)
            swExt = get(obj.Active_Doc, 'Extension');
            swMass = invoke(swExt, 'CreateMassProperty');
            mass = get(swMass,'Mass');
        end
    end
end
