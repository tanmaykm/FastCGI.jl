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

mutable struct ServerRequest
    id::UInt16                          # request id
    state::UInt8                        # 1: init, 2: run, 0: stop
    onclose::Function                   # onclose function to cleanup and close connection if keepconn is false
    in::Channel{FCGIRecord}             # in message channel
    out::Channel{FCGIRecord}            # out message channel (of the connection that originated this request)
    runner::Union{Task,Nothing}         # runner task

    function ServerRequest(id::UInt16, onclose::Function, out::Channel{FCGIRecord})
        req = new(id, 0x1, onclose, Channel{FCGIRecord}(128), out, nothing)
        req.runner = @async process(req)
        req
    end
end
function readparams(req::ServerRequest)
    params = Dict{String,String}()

    # accept params
    while req.state === 0x1
        rec = take!(req.in)
        if rec.header.type === FCGIHeaderType.ABORT_REQUEST
            req.state = 0x0
        elseif rec.header.type === FCGIHeaderType.PARAMS
            if isempty(rec.content)
                # empty params request indicates end of params
                req.state = 0x2
            else
                for nv in FCGIParams(rec.content)
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
end
function monitorabort(req::ServerRequest, process::Base.Process)
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
end
function monitorinputs(req::ServerRequest, inp::Pipe, process::Base.Process)
    streamstdin(req, inp, process)
    (req.state === 0x0) || monitorabort(req, process)   # monitor ABORT_REQUEST if not already aborted
    nothing
end
function monitoroutput(req::ServerRequest, pipe::Pipe, type::UInt8)
    while isopen(pipe)
        bytes = readavailable(pipe)
        isempty(stdoutbytes) || put!(req.out, FCGIRecord(type, req.id, bytes))
    end
end
function monitoroutputs(req::ServerRequest, out::Pipe, err::Pipe)
    @sync begin
        @async monitoroutput(req, out, FCGIHeaderType.STDOUT)
        @async monitoroutput(req, err, FCGIHeaderType.STDERR)
    end
end
function launchproc(req::ServerRequest, params::Dict{String,String}, inp::IOBuffer, out::IOBuffer, err::IOBuffer)
    cmdpath = params["SCRIPT_FILENAME"]
    if !isfile(cmdpath)
        err = "cmdpath not found: $cmdpath"
        @warn(err)
        return 404, err
    end
    try
        cmd = Cmd(`$cmdpath`; env=params)
        process = run(pipeline(cmd, stdin=inp, stdout=out, stderr=err), wait=false)
        return 0, process
    catch ex
        @warn("process exception", cmdpath, params, ex)
        return 500, "process exception"
    end
end
function close(req::ServerRequest, exitcode::Integer, inp::Pipe, out::Pipe, err::Pipe)
    reqcomplete = FCGIEndRequest(UInt32(exitcode), FCGIEndRequestProtocolStatus.REQUEST_COMPLETE)
    put!(req.out, FCGIRecord(FCGIHeaderType.FCGI_END_REQUEST, req.id, reqcomplete))
    close(inp)
    close(out)
    close(err)
    close(req.in)
    (req.onclose)()
    nothing
end
function process(req::ServerRequest)
    params = readparams(req)
    (req.state !== 0x2) && return

    inp = Pipe()
    out = Pipe()
    err = Pipe()
    exitcode, process = launchproc(req, params, inp, out, err)
    if exitcode == 0
        # process was launched successfully
        try
            @sync begin
                @async begin
                    wait(process)
                    exitcode = process.exitcode
                    close(out)
                    close(err)
                    close(req.in)
                end
                @async monitorinputs(req, inp, process) # stream inputs
                @async monitoroutputs(req, out, err) # stream stdout/stderr
            end
        catch ex
            @warn("process exception", ex, params)
            exitcode = 500
        end
    end
    close(req, exitcode, inp, out, err)
end

struct ServerConnection{T<:FCGISocket}
    asock::T
    out::Channel{FCGIRecord}
    requests::Dict{UInt16,ServerRequest}
    processorin::Union{Task,Nothing}
    processorout::Union{Task,Nothing}
    stopsignal::Bool
    onstop::Function
end
function ServerConnection(asock::T, onstop::Function) where {T<:FCGISocket}
    conn = ServerConnection(asock, Channel{FCGIRecord}(128), Dict{UInt16,ServerRequest}(), nothing, nothing, false, onstop)
    conn.processorin = @async processin(conn)
    conn.processorout = @async processout(conn)
    conn
end
function stop(conn::ServerConnection{T}; checkinterval::Float64=0.2) where {T<:FCGISocket}
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
    delete!(conn.requests, reqid)
    keepconn || stop(conn)
    return
end
function processout(conn::ServerConnection{T}) where {T<:FCGISocket}
    # read out channel and write messages on sock
    while !conn.stopsignal && isopen(conn.asock)
        try
            resp = take!(conn.out)
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
            if record.header.type == FCGIHeaderType.BEGIN_REQUEST
                # instantiate request data
                begreq = FCGIBeginRequest(record.content)
                reqrole = role(begreq) 
                (reqrole == FCGIRequestRole.RESPONDER) || error("FCGI feature not supported: role=$reqrole")
                # create a new entry in requests table
                conn.requests[reqid] = ServerRequest(reqid, ()->onclosereq(conn, reqid, keepconn(record.header)))
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
            if !(isa(ex, Base.IOError) && (ex.code == -103))
                @error("unhandled error in connection", ex)
            else
                @info("connection closed")
            end
            close(conn.asock)
            close(conn.out)
            empty!(conn.requests)
            conn.stopsignal = true
        end
    end
    stop(conn)
end

struct FCGIServer{T<:FCGIServerSocket}
    lsock::T
    conns::Vector{ServerConnection}
    processor::Union{Task,Nothing}
    lck::ReentrantLock
end
function FCGIServer(path::String)
    server = FCGIServer(listen(path), Dict{UInt16,ServerConnection}(), nothing, ReentrantLock())
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
#=
function process_incoming(io::T, chan::Channel{FCGIRecord}) where {T<:IO}
    try
        while !eof(io)
            rec = FCGIRecord(io)
            put!(chan, rec)
        end
    catch ex
        eof(io) || rethrow(ex)
    end
end
=#
