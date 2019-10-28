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

struct ServerRequest
    id::UInt16                          # request id
    onclose::Union{Nothing,Function}    # onclose function to close connection if keepconn is false
    in::Channel{FCGIRecord}             # in message channel
    out::Channel{FCGIRecord}            # out message channel
    # process
    # stdin
    # stdout
    # stderr

    function ServerRequest(id::UInt16, onclose::Union{Nothing,Function}, out::Channel{FCGIRecord})
        new(id, onclose, Channel{FCGIRecord}(128), out)
    end
end

struct ServerConnection{T<:FCGISocket}
    asock::T
    out::Channel{FCGIRecord}
    requests::Dict{UInt16,ServerRequest}
    processorin::Union{Task,Nothing}
    processorout::Union{Task,Nothing}
end
function ServerConnection(asock::T) where {T<:FCGISocket}
    conn = ServerConnection(asock, Dict{UInt16,ServerRequest}(), nothing)
    conn.processorin = @async processin(conn)
    conn.processorout = @async processout(conn)
    conn
end
stop(conn::ServerConnection) = (close(conn.asock); nothing)
function processout(conn::ServerConnection{T}) where {T<:FCGISocket}
    # read out channel and write messages on sock
end
function processin(conn::ServerConnection{T}) where {T<:FCGISocket}
    while isopen(conn.asock)
        try
            record = FCGIRecord(conn.asock)
            reqid = requestid(record.header)
            if record.header.type == FCGIHeaderType.BEGIN_REQUEST
                # instantiate request data
                begreq = FCGIBeginRequest(record.content)
                reqrole = role(begreq) 
                (reqrole == FCGIRequestRole.RESPONDER) || error("FCGI feature not supported: role=$reqrole")
                # create a new entry in requests table
                onclose = keepconn(record.header) ? ()->stop(conn) : nothing
                conn.requests[reqid] = ServerRequest(reqid, onclose)
            elseif record.header.type == FCGIHeaderType.GET_VALUES
                # respond with server params
                querynvs = FCGIParams(record.content)
                respnvs = FCGIParams()
                for querynv in querynvs.nvpairs
                    name = querynv.name
                    if name in keys(SERVER_PARAMS)
                        push!(respnvs.nvpairs, FCGINameValuePair(name, SERVER_PARAMS[name]))
                    else
                        @warn("FCGI feature not supported: FCGI_GET_VALUE name=$name")
                    end
                end
            elseif record.header.type in VALID_SERVER_REQ_TYPES
                # push record to process queue
                reqhandler = conn.requests[reqid]
                push!(reqhandler.in, record)
            else
                @warn("FCGI feature not supported: header.type=$(record.header.type)")
                unk = FCGIUnknownType(record.header.type)
            end
        catch ex
            if !(isa(ex, Base.IOError) && (ex.code == -103))
                @error("unhandled error in connection", ex)
                close(conn.asock)
                rethrow(ex)
            else
                @warn("closing connection")
            end
        end
    end
end

struct FCGIServer{T<:FCGIServerSocket}
    lsock::T
    conns::Vector{ServerConnection}
    pruner::Union{Task,Nothing}
    processor::Union{Task,Nothing}
end
function FCGIServer(path::String)
    server = FCGIServer(listen(path), Dict{UInt16,ServerConnection}(), nothing)
    server.pruner = @async prune(server)
    server.processor = @async process(server)
    server
end
stop(server::FCGIServer) = (close(server.lsock); nothing)
function prune(server::FCGIServer{T}) where {T<:FCGIServerSocket}
    while isopen(server.lsock)
        sleep(5)
        filter!(isconnopen, server.conns)
    end
end
function process(server::FCGIServer{T}) where {T<:FCGIServerSocket}
    while isopen(server.lsock)
        try
            push!(server.conns, ServerConnection(accept(server.lsock)))
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


###################
# CLIENT
###################
struct FCGIClient{T<:FCGISocket}
    csock::T
    stdin::IOBuffer
    stdout::IOBuffer
    stderr::IOBuffer
end

function FCGIClient(path::String)
    csock = connect(path)
    FCGIClient(csock, PipeBuffer(), PipeBuffer(), PipeBuffer())
end
