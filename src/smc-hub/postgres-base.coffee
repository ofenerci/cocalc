###
PostgreSQL -- basic queries and database interface

**
This code is currently NOT released under any license for use by anybody except SageMath, Inc.

(c) 2016 SageMath, Inc.
**
###

async   = require('async')
pg      = require('pg')

winston = require('winston')
winston.remove(winston.transports.Console)
winston.add(winston.transports.Console, {level: 'debug', timestamp:true, colorize:true})

misc_node = require('smc-util-node/misc_node')

{defaults} = misc = require('smc-util/misc')
required = defaults.required

{SCHEMA} = require('smc-util/schema')

class exports.PostgreSQL
    constructor: (opts) ->
        opts = defaults opts,
            host     : 'localhost'
            database : 'smc'
            port     : 5432
            debug    : true
            cb       : undefined
        @_debug    = opts.debug
        @_host     = opts.host
        @_port     = opts.port
        @_database = opts.database
        @_concurrent_queries = 0
        @_connect(opts.cb)

    _connect: (cb) =>
        dbg = @_dbg("connect"); dbg()
        async.series([
            (cb) =>
                if @_client?
                    @_client.end(cb)
                else
                    cb()
            (cb) =>
                @_concurrent_queries = 0
                dbg("first make sure db exists")
                @_ensure_database_exists(cb)
            (cb) =>
                @_client = new pg.Client
                    host     : @_host
                    port     : @_port
                    database : @_database
                @_client.on('notification', @_notification)
                @_client.connect(cb)
        ], (err) =>
            if err
                dbg("Failed to connect to database -- #{err}")
                cb?(err)
            else
                dbg("connected!")
                cb?(undefined, @)
        )

    _dbg: (f) =>
        if @_debug
            return (m) => winston.debug("PostgreSQL.#{f}: #{m}")
        else
            return ->

    _notification: (mesg) =>
        dbg = @_dbg("_notification")
        dbg("mesg #{misc.to_json(mesg)}")

    _query: (opts) =>
        opts  = defaults opts,
            query     : required
            params    : []
            cache     : false        # TODO: implement this
            where     : undefined    # Used for SELECT: If given, can be
                                     #  - a map with keys clauses with $::TYPE  (not $1::TYPE!)  and values
                                     #    the corresponding params.  Also, WHERE must not be in the query already.
                                     #    If where[cond] is undefined, then cond is completely **ignored**.
                                     #  - a string, which is inserted as is as a normal WHERE condition.
                                     #  - an array of maps or strings.
            set       : undefined    # Appends a SET clause to the query; same format as values.
            values    : undefined    # Used for INSERT: If given, then params and where must not be given.   Values is a map
                                     # {'field1::type1':value, , 'field2::type2':value2, ...} which gets converted to
                                     # ' (field1, field2, ...) VALUES ($1::type1, $2::type2, ...) '
                                     # with corresponding params set.  Undefined valued fields are ignored and types may be omited.
            conflict  : undefined    # If given, then values must also be given; appends this to query:
                                     #     ON CONFLICT (name) DO UPDATE SET value=EXCLUDED.value'
            jsonb_set : undefined    # Used for setting a field that contains a JSONB javascript map.
                                     # Give as input an object
                                     #
                                     # { field1:{key1:val1, key2:val2, ...}, field2:{key3:val3,...}, ...}
                                     #
                                     # In each field, every key has the corresponding value set, unless val is undefined/null, in which
                                     # case that key is deleted from the JSONB object fieldi.  Simple as that!  This is much, much
                                     # cleaner to use than SQL.   Also, if the value in fieldi itself is NULL, it gets
                                     # created automatically.
            jsonb_merge : undefined  # Exactly lke jsonb_set, but when val1 (say) is an object, it merges that object in,
                                     # *instead of* setting field1[key1]=val1.  So after this field1[key1] has what was in it
                                     # and also what is in val1.  Obviously field1[key1] had better have been an array or NULL.
            order_by    : undefined
            limit       : undefined
            cb          : undefined
        dbg = @_dbg("_query('#{opts.query}') (concurrent=#{@_concurrent_queries})")
        dbg()
        if not @_client?
            # TODO: should also check that client is connected.
            opts.cb?("client not yet initialized")
            return
        if opts.params? and not misc.is_array(opts.params)
            opts.cb?("params must be an array")
            return

        push_param = (param, type) ->
            if type?.toUpperCase() == 'JSONB'
                param = misc.to_json(param)  # I don't understand why this is needed by the driver....
            opts.params.push(param)
            return opts.params.length

        if opts.jsonb_merge?
            if opts.jsonb_set?
                opts.cb?("if jsonb_merge is set then jsonb_set must not be set")
                return
            opts.jsonb_set = opts.jsonb_merge

        SET = []
        if opts.jsonb_set?
            # This little piece of very hard to write (and clever?) code
            # makes it so we can set or **merge in at any nested level (!)
            # arbitrary JSON objects.  We can also delete any key at any
            # level by making the value null or undefined!  This is amazingly
            # easy to use in queries -- basically making JSONP with postgres
            # as expressive as RethinkDB REQL (even better in some ways).
            set = (field, data, path) =>
                obj = "COALESCE(#{field}#>'{#{path.join(',')}}', '{}'::JSONB)"
                for key, val of data
                    if not val?
                        # remove key from object
                        obj = "(#{obj} - '#{key}')"
                    else
                        if opts.jsonb_merge? and (typeof(val) == 'object' and not misc.is_date(val))
                            subobj = set(field, val, path.concat([key]))
                            obj    = "JSONB_SET(#{obj}, '{#{key}}', #{subobj})"
                        else
                            # completely replace field[key] with val.
                            obj = "JSONB_SET(#{obj}, '{#{key}}', $#{push_param(val, 'JSONB')}::JSONB)"
                return obj
            v = ("#{field}=#{set(field, data, [])}" for field, data of opts.jsonb_set)
            SET.push(v...)

        if opts.values?
            #dbg("values = #{misc.to_json(opts.values)}")
            if opts.where?
                opts.cb?("where must not be defined if opts.values is defined")
                return
            fields = []
            values = []
            for field, param of opts.values
                if not param? # ignore undefined fields -- makes code cleaner (and makes sense)
                    continue
                if field.indexOf('::') != -1
                    [field, type] = field.split('::')
                    fields.push(field.trim())
                    type = type.trim()
                    values.push("$#{push_param(param, type)}::#{type}")
                    continue
                else
                    fields.push(field)
                    values.push("$#{push_param(param)}")
            opts.query += " (#{fields.join(', ')}) VALUES (#{values.join(', ')}) "

        if opts.set?
            v = []
            for field, param of opts.set
                if field.indexOf('::') != -1
                    [field, type] = field.split('::')
                    type = type.trim()
                    v.push("#{field.trim()}=$#{push_param(param, type)}::#{type}")
                    continue
                else
                    v.push("#{field.trim()}=$#{push_param(param)}")
            if v.length > 0
                SET.push(v...)

        if opts.conflict?
            if not opts.values?
                opts.cb?("if conflict is specified then values must also be specified")
                return
            if typeof(opts.conflict) != 'string'
                opts.cb?("conflict must be a string (the field name), for now")
                return
            v = ("#{field}=EXCLUDED.#{field}" for field in fields when field != opts.conflict)
            SET.push(v...)
            opts.query += " ON CONFLICT (#{opts.conflict}) DO UPDATE "

        if SET.length > 0
            opts.query += " SET " + SET.join(' , ')

        WHERE = []
        push_where = (x) =>
            if typeof(x) == 'string'
                WHERE.push(x)
            else if misc.is_array(x)
                for v in x
                    push_where(v)
            else if misc.is_object(x)
                for cond, param of x
                    if typeof(cond) != 'string'
                        opts.cb?("each condition must be a string but '#{cond}' isn't")
                        return
                    if not param?  # *IGNORE* where conditions where value is explicitly undefined
                        continue
                    WHERE.push(cond.replace('$', "$#{push_param(param)}"))

        if opts.where?
            push_where(opts.where)

        if WHERE.length > 0
            if opts.values?
                opts.cb?("values must not be given if where clause given")
                return
            opts.query += " WHERE #{WHERE.join(' AND ')}"

        if opts.order_by?
            opts.query += " ORDER BY #{opts.order_by} "

        if opts.limit?
            opts.query += " LIMIT #{opts.limit} "

        dbg("query='#{opts.query}', params=#{misc.to_json(opts.params)}")

        @_concurrent_queries += 1
        try
            @_client.query opts.query, opts.params, (err, result) =>
                @_concurrent_queries -= 1
                if err
                    dbg("done (concurrent=#{@_concurrent_queries}) -- error: #{err}")
                else
                    dbg("done (concurrent=#{@_concurrent_queries}) -- success")
                opts.cb?(err, result)
        catch e
            # this should never ever happen
            dbg("EXCEPTION in @_client.query: #{e}")
            opts.cb?(e)
            @_concurrent_queries -= 1
        return

    # Special case of query for counting entries in a table.
    _count: (opts) =>
        opts  = defaults opts,
            table : required
            where : undefined  # as in _query
            cb    : required
        @_query
            query : "SELECT COUNT(*) FROM #{opts.table}"
            where : opts.where
            cb    : count_result(opts.cb)

    _validate_opts: (opts) =>
        for k, v of opts
            if k.slice(k.length-2) == 'id'
                if v? and not misc.is_valid_uuid_string(v)
                    opts.cb?("invalid #{k} -- #{v}")
                    return false
            if k.slice(k.length-3) == 'ids'
                for w in v
                    if not misc.is_valid_uuid_string(w)
                        opts.cb?("invalid uuid #{w} in #{k} -- #{to_json(v)}")
                        return false
            if k == 'group' and v not in misc.PROJECT_GROUPS
                opts.cb?("unknown project group '#{v}'"); return false
            if k == 'groups'
                for w in v
                    if w not in misc.PROJECT_GROUPS
                        opts.cb?("unknown project group '#{w}' in groups"); return false
        return true

    _ensure_database_exists: (cb) =>
        dbg = @_dbg("_ensure_database_exists")
        dbg("ensure database '#{@_database}' exists")
        misc_node.execute_code
            command : 'psql'
            args    : ['--host', @_host, '--port', @_port,
                       '--list', '--tuples-only']
            cb      : (err, output) =>
                if err
                    cb(err)
                    return
                databases = (x.split('|')[0].trim() for x in output.stdout.split('\n') when x)
                if @_database in databases
                    dbg("database '#{@_database}' already exists")
                    cb()
                    return
                dbg("creating database '#{@_database}'")
                misc_node.execute_code
                    command : 'createdb'
                    args    : ['--host', @_host, '--port', @_port, @_database]
                    cb      : cb

    _confirm_delete: (opts) =>
        opts = defaults opts,
            confirm : 'no'
            cb      : required
        dbg = @_dbg("confirm")
        if opts.confirm != 'yes'
            err = "Really delete all data? -- you must explicitly pass in confirm='yes' (but confirm:'#{opts.confirm}')"
            dbg(err)
            opts.cb(err)
            return false
        else
            return true

    set_random_password: (opts) =>
        throw Error("NotImplementedError")

    # This will fail if any other clients have db open.
    # This function is very important for automated testing.
    delete_entire_database: (opts) =>
        dbg = @_dbg("delete_entire_database")
        dbg("deleting database '#{@_database}'")
        if not @_confirm_delete(opts)
            dbg("failed confirmation")
            return
        async.series([
            (cb) =>
                dbg("disconnect from db")
                @_client.end(cb)
            (cb) =>
                misc_node.execute_code
                    command : 'dropdb'
                    args    : ['--host', @_host, '--port', @_port, @_database]
                    cb      : cb
        ], opts.cb)

    # Deletes all the contents of the tables in the database.  It doesn't
    # delete anything about the schema itself: indexes or tables.
    delete_all: (opts) =>
        dbg = @_dbg("delete_all")
        dbg("deleting all contents of tables in '#{@_database}'")
        if not @_confirm_delete(opts)
            return
        tables = undefined
        async.series([
            (cb) =>
                @_get_tables (err, t) =>
                    tables = t; cb(err)
            (cb) =>
                f = (table, cb) =>
                    @_query
                        query : "DELETE FROM #{table}"
                        cb    : cb
                async.map(tables, f, cb)
        ], opts.cb)

    # return list of tables in the database
    _get_tables: (cb) =>
        @_query
            query : "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
            cb    : (err, result) =>
                if err
                    cb(err)
                else
                    cb(undefined, (row.table_name for row in result.rows))

    # Return list of columns in a given table
    _get_columns: (table, cb) =>
        @_query
            query : "SELECT column_name FROM information_schema.columns"
            where :
                "table_name = $::text" : table
            cb    : (err, result) =>
                if err
                    cb(err)
                else
                    cb(undefined, (row.column_name for row in result.rows))

    _create_table: (table, cb) =>
        dbg = @_dbg("_create_table('#{table}')")
        dbg()
        schema = SCHEMA[table]
        if not schema?
            cb("no table '#{table}' in schema")
            return
        if schema.virtual
            cb("table '#{table}' is virtual")
            return
        columns = []
        primary_keys = []
        for column, info of schema.fields
            if info.deprecated
                continue
            if typeof(info.pg_type) == 'object'
                # compound primary key
                for field, type of info.pg_type
                    columns.push("#{quote_field(field)} #{type}")
                    primary_keys.push(field)
                continue
            s = "#{quote_field(column)} #{pg_type(info)}"
            if info.unique
                s += " UNIQUE"
            if schema.primary_key == column
                primary_keys.push(column)
            columns.push(s)
        if primary_keys.length == 0
            cb("ERROR creating table '#{table}': a valid primary key must be specified -- #{schema.primary_key}")
            return
        async.series([
            (cb) =>
                dbg("creating the table")
                @_query
                    query  : "CREATE TABLE #{table} (#{columns.join(', ')}, PRIMARY KEY(#{primary_keys.join(', ')}))"
                    cb     : cb
            (cb) =>
                @_create_indexes(table, cb)
        ], cb)

    _create_indexes: (table, cb) =>
        dbg = @_dbg("_create_indexes('#{table}')")
        dbg()
        schema = SCHEMA[table]
        pg_indexes = schema.pg_indexes ? []
        if schema.fields.expire? and 'expire' not in pg_indexes
            pg_indexes.push('expire')
        if pg_indexes.length == 0
            dbg("no indexes defined")
            cb()
            return
        dbg("creating indexes")
        f = (query, cb) =>
            s = query.toLowerCase()
            if s.indexOf('create') == -1 or s.indexOf('index') == -1
                # Shorthand index is just the part in parens.
                # Schema can also give a full create index command.
                if query.indexOf('(') == -1
                    query = "(#{query})"
                query = "CREATE INDEX ON #{table} #{query}"
            @_query
                query : query
                cb    : cb
        async.map(pg_indexes, f, cb)

    _throttle: (name, time_s, key...) =>
        key = misc.to_json(key)
        x = "_throttle_#{name}"
        @[x] ?= {}
        if @[x][key]
            return true
        @[x][key] = true
        setTimeout((()=>delete @[x][key]), time_s*1000)
        return false

    # Ensure that the actual schema in the database matches the one defined in SCHEMA.
    # TODO: we do NOT do anything related to the actual columns or datatypes yet!
    update_schema: (opts) =>
        opts = defaults opts,
            cb : undefined
        dbg = @_dbg("update_schema"); dbg()

        psql_tables = goal_tables = undefined
        async.series([
            (cb) =>
                dbg("get tables")
                @_get_tables (err, t) =>
                    psql_tables = t
                    dbg("psql_tables = #{misc.to_json(psql_tables)}")
                    goal_tables = (t for t,s of SCHEMA when t not in psql_tables and not s.virtual)
                    dbg("goal_tables = #{misc.to_json(goal_tables)}")
                    cb(err)
            (cb) =>
                to_create = (table for table in goal_tables when table not in psql_tables)
                if to_create.length == 0
                    dbg("there are no missing tables in psql")
                    cb()
                    return
                async.map to_create, @_create_table, (err) =>
                    if err
                        dbg("error creating tables -- #{err}")
                    cb(err)
        ], (err) => opts.cb?(err))

    # Return the number of outstanding concurrent queries.
    concurrent: () =>
        return @_concurrent_queries

    # Compute the sha1 hash (in hex) of the input arguments, which are
    # converted to strings (via json) if they are not strings, then concatenated.
    # This is used for computing compound primary keys in a way that is relatively
    # safe, and in situations where if there were a highly unlikely collision, it
    # wouldn't be the end of the world.  There is a similar client-only slower version
    # of this function (in schema.coffee), so don't change it willy nilly.
    sha1: (args...) ->
        v = ((if typeof(x) == 'string' then x else JSON.stringify(x)) for x in args).join('')
        return misc_node.sha1(v)

    # Go through every table in the schema with a column called "expire", and
    # delete every entry where expire is <= right now.
    # TODO: I took out everything related to throttling from the RethinkDB
    # version -- maybe postgres is much more efficient!
    delete_expired: (opts) =>
        opts = defaults opts,
            count_only : true       # if true, only count the number of rows that would be deleted
            table      : undefined  # only delete from this table
            cb         : required
        dbg = @_dbg("delete_expired(...)")
        dbg()
        f = (table, cb) =>
            dbg("table='#{table}'")
            if opts.count_only
                @_query
                    query : "SELECT COUNT(*) FROM #{table} WHERE expire <= NOW()"
                    cb    : (err, result) =>
                        if not err
                            dbg("COUNT for table #{table} is #{result.rows[0].count}")
                        cb(err)
            else
                dbg("deleting expired entries from '#{table}'")
                @_query
                    query : "DELETE FROM #{table} WHERE expire <= NOW()"
                    cb    : (err) =>
                        dbg("finished deleting expired entries from '#{table}' -- #{err}")
                        cb(err)
        if opts.table
            tables = [opts.table]
        else
            tables = (k for k, v of SCHEMA when v.fields?.expire? and not v.virtual)
        async.map(tables, f, opts.cb)