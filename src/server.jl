const FCGIServerSocket = Union{Sockets.TCPServer,Sockets.PipeServer}
const FCGISocket = Union{TCPSocket,Base.PipeEndpoint}
const VALID_SERVER_REQ_TYPES = (FCGIHeaderType.ABORT_REQUEST, FCGIHeaderType.PARAMS, FCGIHeaderType.STDIN)
const SERVER_PARAMS = Dict{String,String}(
    "FCGI_MAX_CONNS"    =>  "100",
    "FCGI_MAX_REQS"     =>  "100",
    "FCGI_MPXS_CONNS"   =>  "1"
)

function set_server_param(name::String, value::String)
    SERVER_PARAMS[name] = value
    nothing
end

"""
Holds the runner state.
Items in this struct are needed in the runner task (Runner.runner).
But keeping it in the struct makes it cleaner and also makes them accessible for debugging purpose.
"""
mutable struct Runner
    inp::Pipe                               # stdin
    out::Pipe                               # stdout
    err::Pipe                               # stderr
    process::Union{Base.Process,Nothing}    # launched process
    runner::Union{Task,Nothing}             # runner task
    procmon::Union{Task,Nothing}            # process monitor
    inputmon::Union{Task,Nothing}           # input monitor
    outputmon::Union{Task,Nothing}          # output monitor

    function Runner()
        new(Pipe(), Pipe(), Pipe())
    end
end

mutable struct ServerRequest
    id::UInt16                          # request id
    state::UInt8                        # 1: init, 2: run, 0: stop
    onclose::Function                   # onclose function to cleanup and close connection if keepconn is false
    in::Channel{FCGIRecord}             # in message channel
    out::Channel{FCGIRecord}            # out message channel (of the connection that originated this request)
    runner::Runner                      # runner task

    function ServerRequest(id::UInt16, onclose::Function, out::Channel{FCGIRecord})
        @debug("starting request", id)
        req = new(id, 0x1, onclose, Channel{FCGIRecord}(128), out, Runner())
        req.runner.runner = @async process(req)
        req
    end
end
function readparams(req::ServerRequest)
    params = Dict{String,String}()

    # accept params
    while req.state === 0x1
        @debug("readparams: waiting to take from req.in")
        rec = take!(req.in)
        @debug("readparams: got record", type=reqtypetostring(rec.header.type))
        if rec.header.type === FCGIHeaderType.ABORT_REQUEST
            req.state = 0x0
        elseif rec.header.type === FCGIHeaderType.PARAMS
            if isempty(rec.content)
                @debug("readparams: reached end of params")
                # empty params request indicates end of params
                req.state = 0x2
            else
                @debug("readparams: content", len=length(rec.content))
                for nv in FCGIParams(rec.content).nvpairs
                    params[nv.name] = nv.value
                end
            end
        else
            # ignore (but warn) any unexpected messages for this request id
            @warn("unexpected message type", type=rec.header.type)
        end
    end
    params
end
function streamstdin(req::ServerRequest, inp::Pipe, process::Base.Process)
    @debug("monitorinputs: reading stdin")
    try
        stdinclosed = false
        while !stdinclosed
            rec = take!(req.in)
            if rec.header.type === FCGIHeaderType.ABORT_REQUEST
                kill(process)
                req.state = 0x0
                stdinclosed = true
            elseif rec.header.type === FCGIHeaderType.STDIN
                if isempty(rec.content)
                    stdinclosed = true
                else
                    write(inp, rec.content)
                end
            else
                # ignore (but warn) any unexpected messages for this request id
                @warn("unexpected message type", type=rec.header.type)
            end
        end
    catch ex
        if !isa(ex, InvalidStateException)
            @error("exception in streamstdin", ex)
            rethrow(ex)
        else
            @debug("exiting streamstdin: request closed")
        end
    end
end
function monitorabort(req::ServerRequest, process::Base.Process)
    @debug("monitorinputs: checking abort")
    try
        while req.state !== 0x0
            rec = take!(req.in)
            if rec.header.type === FCGIHeaderType.ABORT_REQUEST
                kill(process)
                req.state = 0x0
            else
                # ignore (but warn) any unexpected messages for this request id
                @warn("unexpected message type", type=rec.header.type)
            end
        end
    catch ex
        if !isa(ex, InvalidStateException)
            @error("exception in monitorabort", ex)
            rethrow(ex)
        else
            @debug("exiting monitorabort: request closed")
        end
    end
end
function monitorinputs(req::ServerRequest)
    inp = req.runner.inp
    process = req.runner.process
    streamstdin(req, inp, process)
    (req.state === 0x0) || monitorabort(req, process)   # monitor ABORT_REQUEST if not already aborted
    nothing
end
function monitoroutput(req::ServerRequest, pipe::Pipe, type::UInt8)
    sent = false
    while isopen(pipe)
        bytes = readavailable(pipe)
        if !isempty(bytes)
            @debug("sending output", type=reqtypetostring(type), nbytes=length(bytes))
            put!(req.out, FCGIRecord(type, req.id, bytes))
            sent = true
        end
    end
    if sent
        # if we ever sent something on a stream, we should send an end marker for it
        @debug("sending end of output", type=reqtypetostring(type))
        put!(req.out, FCGIRecord(type, req.id, UInt8[]))
    end
    @debug("finished monitoroutput", type=reqtypetostring(type))
    nothing
end
function monitoroutputs(req::ServerRequest)
    @sync begin
        @async monitoroutput(req, req.runner.out, FCGIHeaderType.STDOUT)
        @async monitoroutput(req, req.runner.err, FCGIHeaderType.STDERR)
    end
end
function getcommand(params::Dict{String,String})
    get(params, "SCRIPT_FILENAME") do
        params["DOCUMENT_ROOT"] * params["SCRIPT_NAME"]
    end
end
function launchproc(req::ServerRequest, params::Dict{String,String})
    cmdpath = getcommand(params)
    @debug("launching command", cmdpath)
    if !isfile(cmdpath)
        err = "cmdpath not found: $cmdpath"
        @warn(err)
        return 404, err
    end
    try
        cmd = Cmd(`$cmdpath`; env=params)
        req.runner.process = run(pipeline(cmd, stdin=req.runner.inp, stdout=req.runner.out, stderr=req.runner.err), wait=false)
        return 0, ""
    catch ex
        @warn("process exception", cmdpath, params, ex)
        return 500, "process exception"
    end
end
function close(req::ServerRequest, exitcode::Integer)
    @debug("closing request", id=req.id, state=req.state, exitcode)
    reqcomplete = FCGIEndRequest(UInt32(exitcode), FCGIEndRequestProtocolStatus.REQUEST_COMPLETE)
    put!(req.out, FCGIRecord(FCGIHeaderType.END_REQUEST, req.id, reqcomplete))
    close(req)
    nothing
end
function close(req::ServerRequest)
    close(req.runner.inp)
    close(req.runner.out)
    close(req.runner.err)
    close(req.in)
    @debug("calling onclose")
    (req.onclose)()
    nothing
end
function process(req::ServerRequest)
    params = readparams(req)
    @info("processing", SCRIPT_FILENAME=get(params, "SCRIPT_FILENAME", ""), SCRIPT_NAME=get(params, "SCRIPT_NAME", ""))
    @debug("read request params", id=req.id, state=req.state, params)
    if req.state !== 0x2
        @warn("abandoning request", id=req.id)
        return close(req)
    end

    exitcode, errmsg = launchproc(req, params)
    @debug("launched process", exitcode, errmsg)
    if exitcode == 0
        try
            @sync begin
                # process was launched successfully
                req.runner.procmon = @async begin
                    process = req.runner.process
                    wait(process)
                    exitcode = process.exitcode
                    close(req.runner.out)
                    close(req.runner.err)
                    close(req.in)
                end
                req.runner.inputmon = @async monitorinputs(req) # stream inputs
                req.runner.outputmon = @async monitoroutputs(req) # stream stdout/stderr
            end
        catch ex
            @warn("process exception", ex, params)
            exitcode = 500
        end
    end
    close(req, exitcode)
end

mutable struct ServerConnection{T<:FCGISocket}
    asock::T
    out::Channel{FCGIRecord}
    requests::Dict{UInt16,ServerRequest}
    processorin::Union{Task,Nothing}
    processorout::Union{Task,Nothing}
    stopsignal::Bool
    onstop::Function
end
function ServerConnection(asock::T, onstop::Function) where {T<:FCGISocket}
    @debug("accepting server connection")
    conn = ServerConnection(asock, Channel{FCGIRecord}(128), Dict{UInt16,ServerRequest}(), nothing, nothing, false, onstop)
    conn.processorin = @async processin(conn)
    conn.processorout = @async processout(conn)
    conn
end
function stop(conn::ServerConnection{T}; checkinterval::Float64=0.2) where {T<:FCGISocket}
    @debug("stopping server connection")
    while !istaskdone(conn.processorout) && isready(conn.out)
        sleep(checkinterval)
    end
    conn.stopsignal = true
    close(conn.out)
    wait(conn.processorout)
    close(conn.asock)
    wait(conn.processorin)
    empty!(conn.requests)
    (conn.onstop)(conn)
    nothing
end
function onclosereq(conn::ServerConnection{T}, reqid::UInt16, keepconn::Bool) where {T<:FCGISocket}
    @debug("connection onclosereq", reqid, keepconn)
    delete!(conn.requests, reqid)
    keepconn || stop(conn)
    return
end
function processout(conn::ServerConnection{T}) where {T<:FCGISocket}
    # read out channel and write messages on sock
    while !conn.stopsignal && isopen(conn.asock)
        try
            resp = take!(conn.out)
            @debug("writing response packet", type=reqtypetostring(resp.header.type))
            fcgiwrite(conn.asock, resp)
        catch ex
            if !isa(ex, InvalidStateException) && !(isa(ex, Base.IOError) && (ex.code == -103))
                @warn("ServerConnection output processor failed with exception", ex)
            end
            conn.stopsignal = true
            # ignore InvalidStateException and IOError as that signals closing of channel/socket and end of communication
            # cleanups are done by input processor
        end
    end
end
function processin(conn::ServerConnection{T}) where {T<:FCGISocket}
    while !conn.stopsignal && isopen(conn.asock)
        try
            record = FCGIRecord(conn.asock)
            reqid = requestid(record.header)
            @debug("read request packet", reqid, type=reqtypetostring(record.header.type))
            if record.header.type == FCGIHeaderType.BEGIN_REQUEST
                # instantiate request data
                begreq = FCGIBeginRequest(record.content)
                reqrole = role(begreq)
                (reqrole == FCGIRequestRole.RESPONDER) || error("FCGI feature not supported: role=$reqrole")
                # create a new entry in requests table
                @debug("beginning request", keep=keepconn(begreq))
                conn.requests[reqid] = ServerRequest(reqid, ()->onclosereq(conn, reqid, keepconn(begreq)), conn.out)
            elseif record.header.type == FCGIHeaderType.GET_VALUES
                # respond with server params
                querynvs = FCGIParams(record.content)
                respnvs = FCGIParams()
                for querynv in querynvs.nvpairs
                    name = querynv.name
                    if name in keys(SERVER_PARAMS)
                        push!(respnvs.nvpairs, FCGINameValuePair(name, SERVER_PARAMS[name]))
                    else
                        @warn("FCGI feature not supported: FCGI_GET_VALUE", reqid, name)
                    end
                end
                put!(conn.out, FCGIRecord(FCGIHeaderType.GET_VALUES_RESULT, reqid, respnvs))
            elseif record.header.type in VALID_SERVER_REQ_TYPES
                # push record to process queue
                reqhandler = conn.requests[reqid]
                push!(reqhandler.in, record)
            else
                @warn("FCGI feature not supported: header", reqid, type=record.header.type)
                unk = FCGIUnknownType(record.header.type)
                put!(conn.out, FCGIRecord(FCGIHeaderType.UNKNOWN_TYPE, reqid, unk))
            end
        catch ex
            if (isa(ex, Base.IOError) && (ex.code == -103)) || isa(ex, Base.EOFError)
                @debug("connection closed")
            else
                @error("unhandled error in connection", ex)
            end
            close(conn.asock)
            close(conn.out)
            empty!(conn.requests)
            conn.stopsignal = true
        end
    end
    stop(conn)
end

mutable struct FCGIServer{T<:FCGIServerSocket}
    lsock::T
    conns::Vector{ServerConnection}
    processor::Union{Task,Nothing}
    lck::ReentrantLock
end
function FCGIServer(path::String)
    server = FCGIServer(listen(path), Vector{ServerConnection}(), nothing, ReentrantLock())
    server.processor = @async process(server)
    server
end
stop(server::FCGIServer) = (close(server.lsock); nothing)
function delconn(server::FCGIServer, conn::ServerConnection)
    lock(server.lck) do
        filter!((x)->(x !== conn), server.conns)
    end
    nothing
end
function process(server::FCGIServer{T}) where {T<:FCGIServerSocket}
    while isopen(server.lsock)
        try
            push!(server.conns, ServerConnection(accept(server.lsock), (conn)->delconn(server, conn)))
        catch ex
            if !(isa(ex, Base.IOError) && (ex.code == -103))
                @error("unhandled error in server", ex)
                rethrow(ex)
            else
                @warn("stopping server")
            end
        end
    end
end
