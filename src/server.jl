const VALID_SERVER_REQ_TYPES = (FCGIHeaderType.ABORT_REQUEST, FCGIHeaderType.PARAMS, FCGIHeaderType.STDIN)
const SERVER_PARAMS = Dict{String,String}(
    "FCGI_MAX_CONNS"    =>  "100",
    "FCGI_MAX_REQS"     =>  "100",
    "FCGI_MPXS_CONNS"   =>  "1"
)

"""
Set server parameters this server should respond with.
Set values according to resources available on your system and the amount of load you wish this instance to take up.
"""
function set_server_param(name::String, value::String)
    SERVER_PARAMS[name] = value
    nothing
end

"""
The runner type to use. Set this with the `set_server_runner` method.
"""
FCGI_RUNNER = ProcessRunner

"""
Set the runner type to use: `FastCGI.ProcessRunner` or `FastCGI.FunctionRunner`.
"""
function set_server_runner(runnertype)
    @assert supertype(runnertype) === Runner
    global FCGI_RUNNER
    FCGI_RUNNER = runnertype
    nothing
end

"""
Process a single FastCGI client connection.
A client may send multiple requests over the same connection by setting the `keep` flag in the BEGIN_REQUEST message.
Handles all messages that are not specific to any request id (including the BEGIN_REQUEST message that initializes a request).
Initializes and maintains ServerRequest instances for each new request id.
All messages targeted to ongoing request ids are handled over to respective ServerRequest instances.
"""
mutable struct ServerConnection{T<:FCGISocket}
    asock::T
    out::Channel{FCGIRecord}
    requests::Dict{UInt16,ServerRequest}
    processorin::Union{Task,Nothing}
    processorout::Union{Task,Nothing}
    stopsignal::Bool
    onstop::Function
    lck::ReentrantLock
end
function ServerConnection(asock::T, onstop::Function) where {T<:FCGISocket}
    @debug("accepting server connection")
    conn = ServerConnection(asock, Channel{FCGIRecord}(128), Dict{UInt16,ServerRequest}(), nothing, nothing, false, onstop, ReentrantLock())
    conn.processorin = @async processin(conn)
    conn.processorout = @async processout(conn)
    conn
end
function stop(conn::ServerConnection{T}; checkinterval::Float64=0.01) where {T<:FCGISocket}
    @debug("stopping server connection")
    timedwait(checkinterval) do
        istaskdone(conn.processorout) || !isready(conn.out)
    end
    conn.stopsignal = true
    close(conn.out)
    wait(conn.processorout)
    flush(conn.asock)
    close(conn.asock)
    wait(conn.processorin)
    abandonallreq(conn)
    (conn.onstop)(conn)
    nothing
end
function abandonallreq(conn::ServerConnection)
    lock(conn.lck) do
        empty!(conn.requests)
    end
    nothing
end
function addreq(reqf, conn::ServerConnection, reqid::UInt16)
    lock(conn.lck) do
        conn.requests[reqid] = reqf()
    end
    nothing
end
function getreq(conn::ServerConnection, reqid::UInt16)
    lock(conn.lck) do
        get(conn.requests, reqid, nothing)
    end
end
function onclosereq(conn::ServerConnection{T}, reqid::UInt16, keepconn::Bool) where {T<:FCGISocket}
    @debug("connection onclosereq", reqid, keepconn)
    lock(conn.lck) do
        delete!(conn.requests, reqid)
        keepconn || stop(conn)
    end
    return
end
function processout(conn::ServerConnection{T}) where {T<:FCGISocket}
    # read out channel and write messages on sock
    while !conn.stopsignal && isopen(conn.asock)
        try
            resp = take!(conn.out)
            nbytes = fcgiwrite(conn.asock, resp)
            @debug("wrote response packet", type=reqtypetostring(resp.header.type), nbyteswritten=nbytes, contentlen=length(resp.content))
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
                addreq(conn, reqid) do
                    ServerRequest(reqid, ()->onclosereq(conn, reqid, keepconn(begreq)), conn.out)
                end
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
                reqhandler = getreq(conn, reqid)
                if reqhandler === nothing
                    @warn("ignoring invalid request", reqid, type=record.header.type)
                else
                    push!(reqhandler.in, record)
                end
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
            abandonallreq(conn)
            conn.stopsignal = true
        end
    end
    stop(conn)
end

"""
The FCGIServer sets up a listening socket on which it accepts incoming client connections.
For each incoming connection, creates a new ServerConnection instance and starts a separate
processing task for messages from that connection. Maintains a list of such connections.
"""
mutable struct FCGIServer{T<:FCGIServerSocket}
    addr::String
    lsock::T
    conns::Vector{ServerConnection}
    processor::Union{Task,Nothing}
    lck::ReentrantLock
end
function FCGIServer(path::String)
    server = FCGIServer(path, listen(path), Vector{ServerConnection}(), nothing, ReentrantLock())
    server.processor = @async process(server)
    server
end
function FCGIServer(ip::IPv4, port::Integer)
    server = FCGIServer("$(ip):$(Int(port))", listen(ip, port), Vector{ServerConnection}(), nothing, ReentrantLock())
    server.processor = @async process(server)
    server
end
show(io::IO, server::FCGIServer) = print(io, "FCGIServer(", server.addr, ", ", isopen(server.lsock) ? "open" : "closed", ", ", length(server.conns), " connections)")

""" Request stopping of the server by closing the listen socket """
function stop(server::FCGIServer)
    close(server.lsock)
    nothing
end

function delconn(server::FCGIServer, conn::ServerConnection)
    lock(server.lck) do
        filter!((x)->(x !== conn), server.conns)
    end
    nothing
end

""" Whether the server is running and listening for new connections """
isrunning(server::FCGIServer) = isopen(server.lsock)

"""
Processes incoming connections on the listen socket, by creating a separate asynchronous handler for each new connection.
Handling of messages on a connection is implemented in ServerConnection.
"""
function process(server::FCGIServer{T}) where {T<:FCGIServerSocket}
    while isopen(server.lsock)
        try
            asock = accept(server.lsock)
            lock(server.lck) do
                push!(server.conns, ServerConnection(asock, (conn)->delconn(server, conn)))
            end
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
