--!A cross-platform build utility based on Lua
--
-- Licensed to the Apache Software Foundation (ASF) under one
-- or more contributor license agreements.  See the NOTICE file
-- distributed with this work for additional information
-- regarding copyright ownership.  The ASF licenses this file
-- to you under the Apache License, Version 2.0 (the
-- "License"); you may not use this file except in compliance
-- with the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- 
-- Copyright (C) 2015 - 2018, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        object.lua
--

-- imports
import("core.base.option")
import("core.tool.compiler")
import("core.tool.extractor")
import("core.project.rule")
import("core.project.config")
import("core.project.depend")
import("core.project.project")
import("core.language.language")
import("detect.tools.find_ccache")

-- build the object from the *.[o|obj] source file
function _build_from_object(target, sourcefile, objectfile, progress)

    -- is verbose?
    local verbose = option.get("verbose")

    -- trace progress info
    if verbose then
        cprint("${green}[%3d%%]: ${dim magenta}inserting.$(mode) %s", progress, sourcefile)
    else
        cprint("${green}[%3d%%]: ${magenta}inserting.$(mode) %s", progress, sourcefile)
    end

    -- trace verbose info
    if verbose then
        print("cp %s %s", sourcefile, objectfile)
    end

    -- flush io buffer to update progress info
    io.flush()

    -- insert this object file
    os.cp(sourcefile, objectfile)
end

-- build the object from the *.[a|lib] source file
function _build_from_static(target, sourcefile, objectfile, progress)

    -- is verbose?
    local verbose = option.get("verbose")

    -- trace progress info
    if verbose then
        cprint("${green}[%3d%%]: ${dim magenta}inserting.$(mode) %s", progress, sourcefile)
    else
        cprint("${green}[%3d%%]: ${magenta}inserting.$(mode) %s", progress, sourcefile)
    end

    -- trace verbose info
    if verbose then
        print("ex %s %s", sourcefile, objectfile)
    end

    -- flush io buffer to update progress info
    io.flush()

    -- extract the static library to object directory
    extractor.extract(sourcefile, path.directory(objectfile))
end

-- do build file
function _do_build_file(target, sourcefile, opt)

    -- get build info
    local objectfile = opt.objectfile
    local dependfile = opt.dependfile
    local sourcekind = opt.sourcekind
    local progress   = opt.progress

    -- build the object for the *.o/obj source makefile
    if sourcekind == "obj" then 
        return _build_from_object(target, sourcefile, objectfile, progress)
    -- build the object for the *.[a|lib] source file
    elseif sourcekind == "lib" then 
        return _build_from_static(target, sourcefile, objectfile, progress)
    end

    -- load compiler 
    local compinst = compiler.load(sourcekind, {target = target})

    -- get compile flags
    local compflags = compinst:compflags({target = target, sourcefile = sourcefile})

    -- load dependent info 
    local dependinfo = option.get("rebuild") and {} or (depend.load(dependfile) or {})
    
    -- need build this object?
    local depvalues = {compinst:program(), compflags}
    if not depend.is_changed(dependinfo, {lastmtime = os.mtime(objectfile), values = depvalues}) then
        return 
    end

    -- is verbose?
    local verbose = option.get("verbose")

    -- trace progress info
    if verbose then
        cprint("${green}[%3d%%]:${dim} %scompiling.$(mode) %s", progress, _g.ccache and "ccache " or "", sourcefile)
    else
        cprint("${green}[%3d%%]:${clear} %scompiling.$(mode) %s", progress, _g.ccache and "ccache " or "", sourcefile)
    end

    -- trace verbose info
    if verbose then
        print(compinst:compcmd(sourcefile, objectfile, {compflags = compflags}))
    end

    -- flush io buffer to update progress info
    io.flush()

    -- complie it 
    dependinfo.files = {}
    assert(compinst:compile(sourcefile, objectfile, {dependinfo = dependinfo, compflags = compflags}))

    -- update files and values to the dependent file
    dependinfo.values = depvalues
    table.join2(dependinfo.files, sourcefile, target:pcheaderfile("cxx") or {}, target:pcheaderfile("c"))
    depend.save(dependinfo, dependfile)
end

-- build object
function _build_object(target, buildinfo, index, sourcebatch)

    -- get the object and source with the given index
    local sourcefile = sourcebatch.sourcefiles[index]
    local objectfile = sourcebatch.objectfiles[index]
    local dependfile = sourcebatch.dependfiles[index]
    local sourcekind = sourcebatch.sourcekind

    -- calculate progress
    local progress = ((buildinfo.targetindex + (_g.sourceindex + index - 1) / _g.sourcecount) * 100 / buildinfo.targetcount)

    -- init build option
    local opt = {objectfile = objectfile, dependfile = dependfile, sourcekind = sourcekind, progress = progress}

    -- do before build
    local before_build_file = target:script("build_file_before")
    if before_build_file then
        before_build_file(target, sourcefile, opt)
    end

    -- do build 
    local on_build_file = target:script("build_file")
    if on_build_file then
        opt.origin = _do_build_file
        on_build_file(target, sourcefile, opt)
        opt.origin = nil
    else
        _do_build_file(target, sourcefile, opt)
    end

    -- do after build
    local after_build_file = target:script("build_file_after")
    if after_build_file then
        after_build_file(target, sourcefile, opt)
    end
end

-- build each objects from the given source batch
function _build_each_objects(target, buildinfo, sourcekind, sourcebatch, jobs)

    -- run build jobs for each source file 
    local curdir = os.curdir()
    process.runjobs(function (index)

        -- force to set the current directory first because the other jobs maybe changed it
        os.cd(curdir)

        -- build object
        _build_object(target, buildinfo, index, sourcebatch)

    end, #sourcebatch.sourcefiles, jobs)

    -- update object index
    _g.sourceindex = _g.sourceindex + #sourcebatch.sourcefiles
end

-- compile source files to single object at the same time
function _build_single_object(target, buildinfo, sourcekind, sourcebatch, jobs)

    -- is verbose?
    local verbose = option.get("verbose")

    -- get source and object files
    local sourcefiles = sourcebatch.sourcefiles
    local objectfiles = sourcebatch.objectfiles
    local dependfiles = sourcebatch.dependfiles

    -- trace progress info
    for index, sourcefile in ipairs(sourcefiles) do

        -- calculate progress
        local progress = ((buildinfo.targetindex + (_g.sourceindex + index - 1) / _g.sourcecount) * 100 / buildinfo.targetcount)

        -- trace progress info
        if verbose then
            cprint("${green}[%3d%%]:${clear} ${dim}%scompiling.$(mode) %s", progress, _g.ccache and "ccache " or "", sourcefile)
        else
            cprint("${green}[%3d%%]:${clear} %scompiling.$(mode) %s", progress, _g.ccache and "ccache " or "", sourcefile)
        end
    end

    -- trace verbose info
    if verbose then
        print(compiler.compcmd(sourcefiles, objectfiles, {target = target, sourcekind = sourcekind}))
    end

    -- complie them
    compiler.compile(sourcefiles, objectfiles, {dependfiles = dependfiles, target = target, sourcekind = sourcekind})

    -- update object index
    _g.sourceindex = _g.sourceindex + #sourcebatch.sourcefiles
end

-- build precompiled header files (only for c/c++)
function _build_pcheaderfiles(target, buildinfo)

    -- for c/c++
    for _, langkind in ipairs({"c", "cxx"}) do

        -- get the precompiled header
        local pcheaderfile = target:pcheaderfile(langkind)
        if pcheaderfile then

            -- init sourcefile, objectfile and dependfile
            local sourcefile = pcheaderfile
            local objectfile = target:pcoutputfile(langkind)
            local dependfile = objectfile .. ".d"
            local sourcekind = language.langkinds()[langkind]

            -- init source batch
            local sourcebatch = {sourcekind = sourcekind, sourcefiles = {sourcefile}, objectfiles = {objectfile}, dependfiles = {dependfile}}

            -- build this precompiled header
            _build_object(target, buildinfo, 1, sourcebatch, false)
        end
    end
end

-- build source files with the custom rule
function _build_files_with_rule(target, buildinfo, sourcebatch, jobs, suffix)

    -- the rule name
    local rulename = sourcebatch.rulename

    -- get rule instance
    local ruleinst = project.rule(rulename) or rule.rule(rulename)
    assert(ruleinst, "unknown rule: %s", rulename)

    -- on_build_files?
    local on_build_files = ruleinst:script("build_files" .. (suffix and ("_" .. suffix) or ""))
    if on_build_files then

        -- calculate progress
        local progress = (buildinfo.targetindex + _g.sourceindex / _g.sourcecount) * 100 / buildinfo.targetcount

        -- do build files
        on_build_files(target, sourcebatch.sourcefiles, {progress = progress})

        -- update source index
        if not suffix then
            _g.sourceindex = _g.sourceindex + #sourcebatch.sourcefiles
        end
    else
        -- get the build file script
        local on_build_file = ruleinst:script("build_file" .. (suffix and ("_" .. suffix) or ""))
        if on_build_file then

            -- run build jobs for each source file 
            local curdir = os.curdir()
            process.runjobs(function (index)

                -- force to set the current directory first because the other jobs maybe changed it
                os.cd(curdir)

                -- calculate progress
                local progress = ((buildinfo.targetindex + (_g.sourceindex + index - 1) / _g.sourcecount) * 100 / buildinfo.targetcount)
                if suffix then
                    progress = ((buildinfo.targetindex + (suffix == "before" and _g.sourceindex or _g.sourcecount) / _g.sourcecount) * 100 / buildinfo.targetcount)
                end

                -- get source file
                local sourcefile = sourcebatch.sourcefiles[index]

                -- do build file
                on_build_file(target, sourcefile, {progress = progress})

            end, #sourcebatch.sourcefiles, jobs)

            -- update source index
            if not suffix then
                _g.sourceindex = _g.sourceindex + #sourcebatch.sourcefiles
            end
        end
    end
end

-- build objects for the given target
function build(target, buildinfo)

    -- init source index and count
    _g.sourceindex = 0
    _g.sourcecount = target:sourcecount()

    -- get the max job count
    local jobs = tonumber(option.get("jobs") or "4")

    -- get ccache
    if config.get("ccache") then
        _g.ccache = find_ccache()
    end

    -- build source batches with custom rules before building other sources
    for sourcekind, sourcebatch in pairs(target:sourcebatches()) do
        if sourcebatch.rulename then
            _build_files_with_rule(target, buildinfo, sourcebatch, jobs, "before")
        end
    end

    -- build precompiled headers
    _build_pcheaderfiles(target, buildinfo)

    -- build source batches
    for sourcekind, sourcebatch in pairs(target:sourcebatches()) do

        -- compile source files with custom rule
        if sourcebatch.rulename then
            _build_files_with_rule(target, buildinfo, sourcebatch, jobs)
        -- compile source files to single object at once
        elseif type(sourcebatch.objectfiles) == "string" then
            _build_single_object(target, buildinfo, sourcekind, sourcebatch, jobs)
        else
            _build_each_objects(target, buildinfo, sourcekind, sourcebatch, jobs)
        end
    end

    -- build source batches with custom rules after building other sources
    for sourcekind, sourcebatch in pairs(target:sourcebatches()) do
        if sourcebatch.rulename then
            _build_files_with_rule(target, buildinfo, sourcebatch, jobs, "after")
        end
    end
end

