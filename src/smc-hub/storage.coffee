###
Manage storage

CONFIGURATION:  see storage-config.md
###

if process.env.USER != 'root'
    console.warn("WARNING: many functions in storage.coffee will not work if you aren't root!")

{join}      = require('path')
fs          = require('fs')
os          = require('os')

async       = require('async')
winston     = require('winston')

misc_node   = require('smc-util-node/misc_node')

misc        = require('smc-util/misc')
{defaults, required} = misc

# Set the log level
winston.remove(winston.transports.Console)
winston.add(winston.transports.Console, {level: 'debug', timestamp:true, colorize:true})

exclude = () ->
    return ("--exclude=#{x}" for x in misc.split('.sage/cache .sage/temp .trash .Trash .sagemathcloud .smc .node-gyp .cache .forever .snapshots *.sage-backup'))

# Low level function that save all changed files from a compute VM to a local path.
# This must be run as root.
copy_project_from_compute_to_storage = (opts) ->
    opts = defaults opts,
        project_id : required    # uuid
        host       : required    # hostname of computer, e.g., compute2-us
        path       : required    # target path, e.g., /projects0
        max_size_G : 50
        delete     : true
        cb         : required
    dbg = (m) -> winston.debug("copy_project_from_compute_to_storage(project_id='#{opts.project_id}'): #{m}")
    dbg("host='#{opts.host}', path='#{opts.path}'")
    args = ['-axH', "--max-size=#{opts.max_size_G}G", "--ignore-errors"]
    if opts.delete
        args = args.concat(["--delete", "--delete-excluded"])
    else
        args.push('--update')
    args = args.concat(exclude())
    args = args.concat(['-e', 'ssh -T -c arcfour -o Compression=no -x  -o StrictHostKeyChecking=no'])
    source = "#{opts.host}:/projects/#{opts.project_id}/"
    target = "#{opts.path}/#{opts.project_id}/"
    args = args.concat([source, target])
    dbg("starting rsync...")
    start = misc.walltime()
    misc_node.execute_code
        command     : 'rsync'
        args        : args
        timeout     : 10000
        verbose     : true
        err_on_exit : true
        cb          : (err, output) ->
            if err and output?.exit_code == 24 or output?.exit_code == 23
                # exit code 24 = partial transfer due to vanishing files
                # exit code 23 = didn't finish due to permissions; this happens due to fuse mounts
                err = undefined
            dbg("...finished rsync -- time=#{misc.walltime(start)}s")#; #{misc.to_json(output)}")
            opts.cb(err)

# copy_project_from_storage_to_compute NEVER TESTED!
copy_project_from_storage_to_compute = (opts) ->
    opts = defaults opts,
        project_id : required    # uuid
        host       : required    # hostname of computer, e.g., compute2-us
        path       : required    # local source path, e.g., /projects0
        cb         : required
    dbg = (m) -> winston.debug("copy_project_from_storage_to_compute(project_id='#{opts.project_id}'): #{m}")
    dbg("host='#{opts.host}', path='#{opts.path}'")
    args = ['-axH']
    args = args.concat(['-e', 'ssh -T -c arcfour -o Compression=no -x  -o StrictHostKeyChecking=no'])
    source = "#{opts.path}/#{opts.project_id}/"
    target = "#{opts.host}:/projects/#{opts.project_id}/"
    args = args.concat([source, target])
    dbg("starting rsync...")
    start = misc.walltime()
    misc_node.execute_code
        command     : 'rsync'
        args        : args
        timeout     : 10000
        verbose     : true
        err_on_exit : true
        cb          : (out...) ->
            dbg("finished rsync -- time=#{misc.walltime(start)}s")
            opts.cb(out...)

get_storage = (project_id, database, cb) ->
    dbg = (m) -> winston.debug("get_storage(project_id='#{project_id}'): #{m}")
    database.table('projects').get(project_id).pluck(['storage']).run (err, x) ->
        if err
            cb(err)
        else if not x?
            cb("no such project")
        else
            cb(undefined, x.storage?.host)

get_host_and_storage = (project_id, database, cb) ->
    dbg = (m) -> winston.debug("get_host_and_storage(project_id='#{project_id}'): #{m}")
    host = undefined
    storage = undefined
    async.series([
        (cb) ->
            dbg("determine project location info")
            database.table('projects').get(project_id).pluck(['storage', 'host']).run (err, x) ->
                if err
                    cb(err)
                else if not x?
                    cb("no such project")
                else
                    host    = x.host?.host
                    storage = x.storage?.host
                    if not host?
                        cb("project not currently open on a compute host")
                    else
                        cb()
        (cb) ->
            if storage?
                cb()
                return
            dbg("allocate storage host")
            database.table('storage_servers').pluck('host').run (err, x) ->
                if err
                    cb(err)
                else if not x? or x.length == 0
                    cb("no storage servers in storage_server table")
                else
                    # TODO: could choose based on free disk space
                    storage = misc.random_choice((a.host for a in x))
                    database.set_project_storage
                        project_id : project_id
                        host       : storage
                        cb         : cb
    ], (err) ->
        cb(err, {host:host, storage:storage})
    )


# Save project from compute VM to its assigned storage server.  Error if project
# not opened on a compute VM.
exports.save_project = save_project = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required    # uuid
        max_size_G : 50
        cb         : required
    dbg = (m) -> winston.debug("save_project(project_id='#{opts.project_id}'): #{m}")
    host = undefined
    storage = undefined
    async.series([
        (cb) ->
            get_host_and_storage opts.project_id, opts.database, (err, x) ->
                if err
                    cb(err)
                else
                    {host, storage} = x
                    cb()
        (cb) ->
            dbg("do the save")
            copy_project_from_compute_to_storage
                project_id : opts.project_id
                host       : host
                path       : "/" + storage   # TODO: right now all on same computer...
                cb         : cb
        (cb) ->
            dbg("save succeeded -- record in database")
            opts.database.update_project_storage_save
                project_id : opts.project_id
                cb         : cb
    ], (err) -> opts.cb(err))

get_local_volumes = (opts) ->
    opts = defaults opts,
        prefix : 'projects'
        cb     : required
    v = []
    misc_node.execute_code
        command : 'df'
        args    : ['--output=source']
        cb      : (err, output) ->
            if err
                opts.cb(err)
            else
                i = opts.prefix.length
                opts.cb(undefined, (path for path in misc.split(output.stdout).slice(1) when path.indexOf('@') == -1 and path.slice(0,i) == opts.prefix))

###
Save all projects that have been modified in the last age_m minutes
which are stored on this machine.
If there are errors, then will get cb({project_id:'error...', ...})

To save(=rsync over) everything modified in the last week:

s = require('smc-hub/storage'); require('smc-hub/rethink').rethinkdb(hosts:['db0'],pool:1,cb:(err,db)->s.save_recent_projects(database:db, age_m:60*24*7, cb:console.log))



###
exports.save_recent_projects = (opts) ->
    opts = defaults opts,
        database : required
        age_m    : required  # save all projects with last_edited at most this long ago in minutes
        threads  : 5         # number of saves to do at once.
        cb       : required
    dbg = (m) -> winston.debug("save_all_projects(last_edited_m:#{opts.age_m}): #{m}")
    dbg()

    errors        = {}
    local_volumes = {}
    projects      = undefined
    async.series([
        (cb) ->
            dbg("determine local volumes")
            get_local_volumes
                prefix : 'projects'
                cb     : (err, v) ->
                    if err
                        cb(err)
                    else
                        for path in v
                            local_volumes[path] = true
                        dbg("local volumes are #{misc.to_json(misc.keys(local_volumes))}")
                        cb()
        (cb) ->
            dbg("get all recently modified projects from the database")
            opts.database.recent_projects
                age_m : opts.age_m
                pluck : ['project_id', 'storage']
                cb    : (err, v) ->
                    if err
                        cb(err)
                    else
                        dbg("got #{v.length} recently modified projects")
                        # we could do this filtering on the server, but for little gain
                        projects = (x.project_id for x in v when local_volumes[x.storage?.host])
                        dbg("got #{projects.length} projects stored here")
                        cb()
        (cb) ->
            dbg("save each modified project")
            n = 0
            f = (project_id, cb) ->
                n += 1
                m = n
                dbg("#{m}/#{projects.length}: START")
                save_project
                    project_id : project_id
                    database   : opts.database
                    cb         : (err) ->
                        dbg("#{m}/#{projects.length}: DONE  -- #{err}")
                        if err
                            errors[project_id] = err
                        cb()
            async.mapLimit(projects, opts.threads, f, cb)
        ], (err) ->
            opts.cb(if misc.len(errors) > 0 then errors)
    )

# NEVER TESTED - DOES NOT WORK YET
# Open project on a given compute server (so copy from storage to compute server).
# Error if project is already open on a server.
exports.open_project = open_project = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("open_project(project_id='#{opts.project_id}'): #{m}")
    host = undefined
    storage = undefined
    async.series([
        (cb) ->
            dbg('make sure project is not already opened somewhere')
            opts.database.get_project_host
                project_id : opts.project_id
                cb         : (err, x) ->
                    if err
                        cb(err)
                    else
                        if x?.host?
                            cb("project already opened")
                        else
                            cb()
        (cb) ->
            get_host_and_storage opts.project_id, opts.database, (err, x) ->
                if err
                    cb(err)
                else
                    {host, storage} = x
                    cb()
        (cb) ->
            dbg("do the open")
            copy_project_from_storage_to_compute
                project_id : opts.project_id
                host       : host
                path       : "/" + storage   # TODO: right now all on same computer...
                cb         : cb
        (cb) ->
            dbg("open succeeded -- record in database")
            opts.database.set_project_host
                project_id : opts.project_id
                host       : host
                cb         : cb
    ], opts.cb)


###
Snapshoting projects using bup
###

BUCKET = 'smc-projects-bup'  # if given, will upload there using gsutil rsync

###
Must run as root:

db = require('smc-hub/rethink').rethinkdb(hosts:['db0'],pool:1); s = require('smc-hub/storage');

# make sure everything from 2 years ago (or older) has a backup
s.backup_projects(database:db, min_age_m:2 * 60*24*365, age_m:1e8, time_since_last_backup_m:1e8, cb:(e)->console.log("DONE",e))

# make sure everything modified in the last week has at least one backup made within
# the last day (if it was backed up after last edited, it won't be backed up again)
s.backup_projects(database:db, age_m:7*24*60, time_since_last_backup_m:60*24, threads:1, cb:(e)->console.log("DONE",e))
###
exports.backup_projects = (opts) ->
    opts = defaults opts,
        database  : required
        age_m     : undefined  # if given, select projects at most this old
        min_age_m : undefined  # if given, selects only projects that are at least this old
        bucket    : BUCKET
        threads   : 1
        time_since_last_backup_m : undefined  # if given, only backup projects for which it has been at least this long since they were backed up
        cb        : required
    projects = undefined
    dbg = (m) -> winston.debug("backup_projects: #{m}")
    dbg("age_m=#{opts.age_m}; min_age_m=#{opts.min_age_m}; time_since_last_backup_m=#{opts.time_since_last_backup_m}")
    async.series([
        (cb) ->
            if opts.time_since_last_backup_m?
                opts.database.recent_projects
                    age_m     : opts.age_m
                    min_age_m : opts.min_age_m
                    pluck     : ['last_backup', 'project_id', 'last_edited']
                    cb        : (err, v) ->
                        if err
                            cb(err)
                        else
                            dbg("got #{v.length} recent projects")
                            projects = []
                            cutoff = misc.minutes_ago(opts.time_since_last_backup_m)
                            for x in v
                                if x.last_backup? and x.last_edited? and x.last_backup >= x.last_edited
                                    # no need to make another backup, since already have an up to date backup
                                    continue
                                if not x.last_backup? or x.last_backup <= cutoff
                                    projects.push(x.project_id)
                            dbg("of these recent projects, #{projects.length} DO NOT have a backup made within the last #{opts.time_since_last_backup_m} minutes")
                            cb()
            else
                opts.database.recent_projects
                    age_m     : opts.age_m
                    min_age_m : opts.min_age_m
                    cb        : (err, v) ->
                        projects = v
                        cb(err)
        (cb) ->
            dbg("making backup of #{projects.length} projects")
            backup_many_projects
                database : opts.database
                projects : projects
                bucket   : opts.bucket
                threads  : opts.threads
                cb       : cb
        ], opts.cb)

backup_many_projects = (opts) ->
    opts = defaults opts,
        database : required
        projects : required
        bucket   : BUCKET
        threads  : 1
        cb       : required
    # back up a list of projects that are stored on this computer
    dbg = (m) -> winston.debug("backup_projects(projects.length=#{opts.projects.length}): #{m}")
    dbg("threads=#{opts.threads}, bucket='#{opts.bucket}'")
    errors = {}
    n = 0
    done = 0
    f = (project_id, cb) ->
        n += 1
        m = n
        dbg("#{m}/#{opts.projects.length}: backing up #{project_id}")
        backup_one_project
            database   : opts.database
            project_id : project_id
            bucket     : opts.bucket
            cb         : (err) ->
                done += 1
                dbg("#{m}/#{opts.projects.length}: #{done} DONE #{project_id} -- #{err}")
                if done >= opts.projects.length
                    dbg("**COMPLETELY DONE!!**")
                if err
                    errors[project_id] = err
                cb()
    finish = ->
        if misc.len(errors) == 0
            opts.cb()
        else
            opts.cb(errors)
    async.mapLimit(opts.projects, opts.threads, f, finish)


# Make snapshot of project using bup to local cache, then
# rsync that repo to google cloud storage.  Records successful
# save in the database.  Must be run as root.
backup_one_project = exports.backup_one_project = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        bucket     : BUCKET
        cb         : required
    dbg = (m) -> winston.debug("backup_project(project_id='#{opts.project_id}'): #{m}")
    dbg()
    projects_path = exists = bup = bup1 = undefined
    async.series([
        (cb) ->
            dbg("determine volume containing project")
            get_storage opts.project_id, opts.database, (err, storage) ->
                if err
                    cb(err)
                else
                    projects_path = "/" + storage
                    cb()
        (cb) ->
            fs.exists join(projects_path, opts.project_id), (_exists) ->
                # not an error -- this just means project was never used at all (and saved)
                exists = _exists
                cb()
        (cb) ->
            if not exists
                cb(); return
            dbg("saving project to local bup repo")
            bup_save_project
                projects_path : projects_path
                project_id    : opts.project_id
                cb            : (err, _bup) ->
                    if err
                        cb(err)
                    else
                        bup = _bup           # probably "/bup/#{project_id}/{timestamp}"
                        i = bup.indexOf(opts.project_id)
                        if i == -1
                            cb("bup path must contain project_id")
                        else
                            bup1 = bup.slice(i)  # "#{project_id}/{timestamp}"
                            cb()
        (cb) ->
            if not exists
                cb(); return
            if not opts.bucket
                cb(); return
            async.parallel([
                (cb) ->
                    dbg("rsync'ing pack files")
                    # Upload new pack file objects -- don't use -c, since it would be very (!!) slow on these
                    # huge files, and isn't needed, since time stamps are enough.  We also don't save the
                    # midx and bloom files, since they also can be recreated from the pack files.
                    misc_node.execute_code
                        timeout : 2*3600
                        command : 'gsutil'
                        args    : ['-m', 'rsync', '-x', '.*\.bloom|.*\.midx', '-r', bup+'/objects/', "gs://#{opts.bucket}/#{bup1}/objects/"]
                        cb      : cb
                (cb) ->
                    dbg("rsync'ing refs and logs files")
                    f = (path, cb) ->
                        # upload refs; using -c below is critical, since filenames don't change but content does (and timestamps aren't
                        # used by gsutil!).
                        misc_node.execute_code
                            timeout : 300
                            command : 'gsutil'
                            args    : ['-m', 'rsync', '-c', '-r', bup+"/#{path}/", "gs://#{opts.bucket}/#{bup1}/#{path}/"]
                            cb      : cb
                    async.map(['refs', 'logs'], f, cb)
                    # NOTE: we don't save HEAD, since it is always "ref: refs/heads/master"
            ], cb)
        (cb) ->
            dbg("recording successful backup in database")
            opts.database.table('projects').get(opts.project_id).update(last_backup: new Date()).run(cb)
    ], (err) -> opts.cb(err))


# this must be run as root.
bup_save_project = (opts) ->
    opts = defaults opts,
        projects_path : required   # e.g., '/projects3'
        project_id    : required
        cb            : required   # opts.cb(err, BUP_DIR)
    dbg = (m) -> winston.debug("bup_save_project(project_id='#{opts.project_id}'): #{m}")
    dbg()
    source = join(opts.projects_path, opts.project_id)
    dir = "/bup/#{opts.project_id}"
    bup = undefined # will be set below to abs path of newest bup repo
    async.series([
        (cb) ->
            dbg("create target bup repo")
            fs.exists dir, (exists) ->
                if exists
                    cb()
                else
                    fs.mkdir(dir, cb)
        (cb) ->
            dbg('ensure there is a bup repo')
            fs.readdir dir, (err, files) ->
                if err
                    cb(err)
                else
                    files = files.sort()
                    if files.length > 0
                        bup = join(dir, files[files.length-1])
                    cb()
        (cb) ->
            if bup?
                cb(); return
            dbg("must create bup repo")
            bup = join(dir, misc.date_to_snapshot_format(new Date()))
            fs.mkdir(bup, cb)
        (cb) ->
            dbg("init bup repo")
            misc_node.execute_code
                command : 'bup'
                args    : ['init']
                timeout : 120
                env     : {BUP_DIR:bup}
                cb      : cb
        (cb) ->
            dbg("index the project")
            misc_node.execute_code
                command : 'bup'
                args    : ['index', source]
                timeout : 60*30   # 30 minutes
                env     : {BUP_DIR:bup}
                cb      : cb
        (cb) ->
            dbg("save the bup snapshot")
            misc_node.execute_code
                command : 'bup'
                args    : ['save', source, '-n', 'master', '--strip']
                timeout : 60*60*2  # 2 hours
                env     : {BUP_DIR:bup}
                cb      : cb
        (cb) ->
            dbg('ensure that all backup files are readable by the salvus user (only user on this system)')
            misc_node.execute_code
                command : 'chmod'
                args    : ['a+r', '-R', bup]
                timeout : 60
                cb      : cb
    ], (err) ->
        opts.cb(err, bup)
    )

# Copy most recent bup archive of project to local bup cache, put the HEAD file in,
# then restore the most recent snapshot in the archive to the local projects path.
exports.restore_project = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        bucket     : BUCKET
        cb         : required
    dbg = (m) -> winston.debug("restore_project(project_id='#{opts.project_id}'): #{m}")
    dbg()
    volume = undefined
    async.series([
        (cb) ->
            dbg("update/get bup rep from google cloud storage")
            restore_bup_from_gcloud
                project_id : opts.project_id
                bucket     : opts.bucket
                cb         : cb
        (cb) ->
            dbg("determine target local volume for project")
            get_local_volumes
                cb : (err, volumes) ->
                    if err
                        cb(err)
                    else
                        volume = misc.random_choice(volumes)
                        cb()
        (cb) ->
            dbg("extract project")
            restore_project_from_bup
                project_id    : opts.project_id
                projects_path : '/' + volume
                cb            : cb
        (cb) ->
            dbg("record that project is now saved here")
            opts.database.update_project_storage_save
                project_id : opts.project_id
                cb         : cb
    ], (err)->opts.cb(err))

# Extract most recent snapshot of project from local bup archive to a
# local directory.  bup archive is assumed to be in /bup/project_id/[timestamp].
restore_project_from_bup = (opts) ->
    opts = defaults opts,
        project_id    : required
        projects_path : required   # project will be restored to projects_path/project_id, which must not exist
        cb            : required
    dbg = (m) -> winston.debug("restore_project_from_bup(project_id='#{opts.project_id}'): #{m}")
    dbg()
    outdir = "#{opts.projects_path}/#{opts.project_id}"
    local_path = "/bup/#{opts.project_id}"
    bup = undefined
    async.series([
        (cb) ->
            fs.readdir local_path, (err, files) ->
                if err
                    cb(err)
                else
                    if files.length > 0
                        files.sort()
                        snapshot = files[files.length-1]  # newest snapshot
                        bup = join(local_path, snapshot)
                    cb()
        (cb) ->
            if not bup?
                # nothing to do -- no bup repos made yet
                cb(); return
            misc_node.execute_code
                command : 'bup'
                args    : ['restore', '--outdir', outdir, 'master/latest/']
                env     : {BUP_DIR:bup}
                cb      : cb
    ], (err)->opts.cb(err))

restore_bup_from_gcloud = (opts) ->
    opts = defaults opts,
        project_id : required
        bucket     : BUCKET
        cb         : required    # cb(err, path_to_bup_repo or undefined if no repo in cloud)
    dbg = (m) -> winston.debug("restore_bup_from_gcloud(project_id='#{opts.project_id}'): #{m}")
    dbg()
    bup = source = undefined
    async.series([
        (cb) ->
            if not opts.bucket?
                # no bucket specified
                cb(); return
            dbg("rsync bup repo from Google cloud storage -- first get list of available repos")
            misc_node.execute_code
                timeout : 120
                command : 'gsutil'
                args    : ['ls', "gs://smc-projects-bup/#{opts.project_id}"]
                cb      : (err, output) ->
                    if err
                        cb(err)
                    else
                        v = misc.split(output.stdout).sort()
                        if v.length > 0
                            source = v[v.length-1]   # like 'gs://smc-projects-bup/06e7df74-b68b-4370-9cdc-86aec577e162/2015-12-05-041330/'
                            dbg("most recent bup repo '#{source}'")
                            timestamp = require('path').parse(source).name
                            bup = "/bup/#{opts.project_id}/#{timestamp}"
                        else
                            dbg("no known backups at all")
                        cb()
        (cb) ->
            if not source?
                cb(); return
            misc_node.ensure_containing_directory_exists(bup+"/HEAD", cb)
        (cb) ->
            if not source?
                cb(); return
            async.parallel([
                (cb) ->
                    dbg("rsync'ing pack files")
                    fs.mkdir bup+'/objects', ->
                        misc_node.execute_code
                            timeout : 2*3600
                            command : 'gsutil'
                            args    : ['-m', 'rsync', '-r', "#{source}objects/", bup+'/objects/']
                            cb      : cb
                (cb) ->
                    dbg("rsync'ing refs files")
                    fs.mkdir bup+'/refs', ->
                        misc_node.execute_code
                            timeout : 2*3600
                            command : 'gsutil'
                            args    : ['-m', 'rsync', '-c', '-r', "#{source}refs/", bup+'/refs/']
                            cb      : cb
                (cb) ->
                    dbg("creating HEAD")
                    fs.writeFile(join(bup, 'HEAD'), 'ref: refs/heads/master', cb)
            ], cb)
    ], (err) -> opts.cb(err, bup))

# Make sure everything modified in the last week has at least one backup made within
# the last day (if it was backed up after last edited, it won't be backed up again).
# For now we just run this (from the update_backups script) once per day to ensure
# we have useful offsite backups.
exports.update_backups = () ->
    db = undefined
    async.series([
        (cb) ->
            require('./rethink').rethinkdb
                hosts : ['db0']
                pool  : 1
                cb    : (err, x) ->
                    db = x
                    cb(err)
        (cb) ->
            exports.backup_projects
                database                 : db
                age_m                    : 60*24*7
                time_since_last_backup_m : 60*24
                threads                  : 1
                cb                       : cb
    ], (err) ->
        winston.debug("!DONE! #{err}")
        process.exit(if err then 1 else 0)
    )

# Probably soon we won't need this since projects will get storage
# assigned right when they are created.
exports.assign_storage_to_all_projects = (database, cb) ->
    # Ensure that every project is assigned to some storage host.
    dbg = (m) -> winston.debug("assign_storage_to_all_projects: #{m}")
    dbg()
    projects = hosts = undefined
    async.series([
        (cb) ->
            dbg("get projects with no assigned storage")
            database.table('projects').filter((row)->row.hasFields({storage:true}).not()).pluck('project_id').run (err, v) ->
                dbg("get #{v?.length} projects")
                projects = v; cb(err)
        (cb) ->
            database.table('storage_servers').pluck('host').run (err, v) ->
                if err
                    cb(err)
                else
                    dbg("got hosts: #{misc.to_json(v)}")
                    hosts = (x.host for x in v)
                    cb()
        (cb) ->
            n = 0
            f = (project, cb) ->
                n += 1
                {project_id} = project
                host = misc.random_choice(hosts)
                dbg("#{n}/#{projects.length}: assigning #{project_id} to #{host}")
                database.get_project_storage  # do a quick check that storage isn't defined -- maybe slightly avoid race condition (we are being lazy)
                    project_id : project_id
                    cb         : (err, storage) ->
                        if err or storage?
                            cb(err)
                        else
                            database.set_project_storage
                                project_id : project_id
                                host       : host
                                cb         : cb
            async.mapLimit(projects, 10, f, cb)
    ], cb)

exports.update_storage = () ->
    # This should be run from the command line.
    # It checks that it isn't already running.  If not, it then
    # writes a pid file, copies everything over that was modified
    # since last time the pid file was written, then updates
    # all snapshots and exits.
    fs = require('fs')
    path = require('path')
    PID_FILE = '/home/salvus/.update_storage.pid'
    dbg = (m) -> winston.debug("update_storage: #{m}")
    last_pid = undefined
    last_run = undefined
    database = undefined
    local_volumes = undefined
    async.series([
        (cb) ->
            dbg("read pid file #{PID_FILE}")
            fs.readFile PID_FILE, (err, data) ->
                if not err
                    last_pid = data.toString()
                cb()
        (cb) ->
            if last_pid?
                try
                    process.kill(last_pid, 0)
                    cb("previous process still running")
                catch e
                    dbg("good -- process not running")
                    cb()
            else
                cb()
        (cb) ->
            if last_pid?
                fs.stat PID_FILE, (err, stats) ->
                    if err
                        cb(err)
                    else
                        last_run = stats.mtime
                        cb()
            else
                last_run = misc.days_ago(1) # go back one day the first time
                cb()
        (cb) ->
            dbg("last run: #{last_run}")
            dbg("create new pid file")
            fs.writeFile(PID_FILE, "#{process.pid}", cb)
        (cb) ->
            # TODO: clearly this is hardcoded!
            require('smc-hub/rethink').rethinkdb
                hosts : ['db0']
                pool  : 1
                cb    : (err, db) ->
                    database = db
                    cb(err)
        (cb) ->
            exports.assign_storage_to_all_projects(database, cb)
        (cb) ->
            exports.save_recent_projects
                database : database
                age_m    : (new Date() - last_run)/1000/60
                threads  : 10
                cb       : (err) ->
                    dbg("save_all_projects returned errors=#{misc.to_json(err)}")
                    cb()
        (cb) ->
            get_local_volumes
                prefix : 'projects'
                cb     : (err, v) ->
                    local_volumes = v
                    cb(err)
        (cb) ->
            {update_snapshots} = require('./rolling_snapshots')
            f = (volume, cb) ->
                update_snapshots
                    filesystem : volume
                    cb         : cb
            async.map(local_volumes, f, cb)
    ], (err) ->
        dbg("finished -- err=#{err}")
        if err
            process.exit(1)
        else
            process.exit(0)
    )


exports.mount_snapshots_on_all_compute_vms_command_line = ->
    database = undefined
    async.series([
        (cb) ->
            require('smc-hub/rethink').rethinkdb
                hosts : ['db0']
                pool  : 1
                cb    : (err, db) ->
                    database = db; cb(err)
        (cb) ->
            exports.mount_snapshots_on_all_compute_vms
                database : database
                cb       : cb
    ], (err) ->
        if err
            process.exit(1)
        else
            winston.debug("SUCCESS!")
            process.exit(0)
    )

###
db = require('smc-hub/rethink').rethinkdb(hosts:['db0'], pool:1); s = require('smc-hub/storage'); 0;
s.mount_snapshots_on_all_compute_vms(database:db, cb:console.log)
###
exports.mount_snapshots_on_all_compute_vms = (opts) ->
    opts = defaults opts,
        database : required
        cb       : required   # cb() or cb({host:error, ..., host:error})
    dbg = (m) -> winston.debug("mount_snapshots_on_all_compute_vm: #{m}")
    server = os.hostname()  # name of this server
    hosts = undefined
    errors = {}
    async.series([
        (cb) ->
            dbg("check that sshd is setup with important restrictions (slightly limits damage in case compute machine is rooted)")
            fs.readFile '/etc/ssh/sshd_config', (err, data) ->
                if err
                    cb(err)
                else if data.toString().indexOf("Match User root") == -1
                    cb("Put this in /etc/ssh/sshd_config, then 'service sshd restart'!:\n\nMatch User root\n\tChrootDirectory /projects4/.zfs/snapshot\n\tForceCommand internal-sftp")
                else
                    cb()
        (cb) ->
            dbg("ensure all local snapshots are mounted (should take at most 30s) -- due to sftp chroot we need to do this, since zfs automount doesn't work")
            misc_node.execute_code
                bash    : true  # important to use bash shell so that * below works
                command : "ls /#{server}/.zfs/snapshot/*/NO_SUCH_FILE"
                timeout : 120
                cb      : (err) ->
                    cb()  # explicitly ignore the error we get due to NO_SUCH_FILE
        (cb) ->
            dbg("query database for all compute vm's")
            opts.database.get_all_compute_servers
                cb : (err, v) ->
                    if err
                        cb(err)
                    else
                        hosts = (x.host for x in v)
                        cb()
        (cb) ->
            dbg("mounting snapshots on all compute vm's")
            errors = {}
            f = (host, cb) ->
                exports.mount_snapshots_on_cofmpute_vm
                    host : host
                    cb   : (err) ->
                        if err
                            errors[host] = err
                        cb()
            async.map(hosts, f, cb)
    ], (err) ->
        if err
            opts.cb(err)
        else if misc.len(errors) > 0
            opts.cb(errors)
        else
            opts.cb()
    )

# ssh to the given compute server and setup an sshfs mount on
# it to this machine, if it isn't already setup.
# This must be run as root.
exports.mount_snapshots_on_compute_vm = (opts) ->
    opts = defaults opts,
        host : required     # hostname of compute server
        cb   : required
    server = os.hostname()  # name of this server
    mnt    = "/mnt/snapshots/#{server}/"
    remote = "fusermount -u -z #{mnt}; mkdir -p #{mnt}/; chmod a+rx /mnt/snapshots/ #{mnt}; sshfs -o ro,allow_other,default_permissions #{server}:/ #{mnt}/"
    winston.debug("mount_snapshots_on_compute_vm(host='#{opts.host}'): run this on #{opts.host}:   #{remote}")
    misc_node.execute_code
        command : 'ssh'
        args    : [opts.host, remote]
        timeout : 120
        cb      : opts.cb

###
Everything below is one-off code -- has no value, except as examples.
###


# Slow one-off function that goes through database, reads each storage field for project,
# and writes it in a different format: {host:host, assigned:assigned}.
###
exports.update_storage_field = (opts) ->
    opts = defaults opts,
        db      : required
        lower   : required
        upper   : required
        limit   : undefined
        threads : 1
        cb      : required
    dbg = (m) -> winston.debug("update_storage_field: #{m}")
    dbg("query database for projects with id between #{opts.lower} and #{opts.upper}")
    query = opts.db.table('projects').between(opts.lower, opts.upper)
    query = query.pluck('project_id', 'storage')
    if opts.limit?
        query = query.limit(opts.limit)
    query.run (err, x) ->
        if err
            opts.cb(err)
        else
            dbg("got #{x.length} results")
            n = 0
            f = (project, cb) ->
                n += 1
                dbg("#{n}/#{x.length}: #{misc.to_json(project)}")
                if project.storage? and not project.storage?.host?
                    y = undefined
                    for host, assigned of project.storage
                        y = {host:host, assigned:assigned}
                    if y?
                        dbg(misc.to_json(y))
                        opts.db.table('projects').get(project.project_id).update(storage:opts.db.r.literal(y)).run(cb)
                    else
                        cb()
                else
                    cb()
            async.mapLimit(x, opts.threads, f, (err)=>opts.cb(err))


exports.update_storage_field2 = (opts) ->
    opts = defaults opts,
        db      : required
        threads : 10
        cb      : required
    dbg = (m) -> winston.debug("update_storage_field: #{m}")
    query = opts.db.table('projects').pluck('project_id', 'storage')
    query.run (err, x) ->
        if err
            opts.cb(err)
        else
            dbg("got #{x.length} results")
            n = 0
            f = (project, cb) ->
                n += 1
                if project.storage?.host?
                    dbg("#{n}/#{x.length}: #{misc.to_json(project)}")
                    if project.storage.host == 'projects2'
                        project.storage.host = 'projects3'
                        opts.db.table('projects').get(project.project_id).update(storage:opts.db.r.literal(project.storage)).run(cb)
                    else if project.storage.host == 'projects3'
                        project.storage.host = 'projects2'
                        opts.db.table('projects').get(project.project_id).update(storage:opts.db.r.literal(project.storage)).run(cb)
                    else
                        cb()
                else
                    cb()
            async.mapLimit(x, opts.threads, f, (err)=>opts.cb(err))



# A one-off function that queries for some projects
# in the database that don't have storage set, and assigns them a given host,
# then copies their data to that host.

exports.migrate_projects = (opts) ->
    opts = defaults opts,
        db      : required
        lower   : required
        upper   : required
        host    : 'projects0'
        all     : false
        limit   : undefined
        threads : 1
        cb      : required
    dbg = (m) -> winston.debug("migrate_projects: #{m}")
    projects = undefined
    async.series([
        (cb) ->
            dbg("query database for projects with id between #{opts.lower} and #{opts.upper}")
            query = opts.db.table('projects').between(opts.lower, opts.upper)
            if not opts.all
                query = query.filter({storage:true}, {default:true})
            query = query.pluck('project_id')
            if opts.limit?
                query = query.limit(opts.limit)
            query.run (err, x) ->
                projects = x; cb(err)
        (cb) ->
            n = 0
            migrate_project = (project, cb) ->
                {project_id} = project
                m = n
                dbg("#{m}/#{projects.length-1}: do rsync for #{project_id}")
                src = "/projects/#{project_id}/"
                n += 1
                fs.exists src, (exists) ->
                    if not exists
                        dbg("#{m}/#{projects.length-1}: #{src} -- source not available -- setting storage to empty map")
                        opts.db.table('projects').get(project_id).update(storage:{}).run(cb)
                    else
                        cmd = "sudo rsync -axH --exclude .sage #{src}    /#{opts.host}/#{project_id}/"
                        dbg("#{m}/#{projects.length-1}: " + cmd)
                        misc_node.execute_code
                            command     : cmd
                            timeout     : 10000
                            verbose     : true
                            err_on_exit : true
                            cb          : (err) ->
                                if err
                                    cb(err)
                                else
                                    dbg("it worked, set storage entry in database")
                                    opts.db.table('projects').get(project_id).update(storage:{"#{opts.host}":new Date()}).run(cb)

            async.mapLimit(projects, opts.threads, migrate_project, cb)

    ], (err) ->
        opts.cb?(err)
    )


###

