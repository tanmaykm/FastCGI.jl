mutable struct FCGIRequest
    headers::Dict{String,String}
    in::IO
    out::IO
    err::IO
    keepconn::Bool
    isdone::Channel{Nothing}
    exception::Any
    function FCGIRequest(; headers::Dict{String,String}=Dict{String,String}(), in::IO=PipeBuffer(), out::IO=PipeBuffer(), err::IO=PipeBuffer(), keepconn::Bool=false)
        new(headers, in, out, err, keepconn, Channel{Nothing}(1), nothing)
    end
end
show(io::IO, request::FCGIRequest) = print(io, "FCGIRequest(", "complete=", isready(request.isdone), ", keepconn=", request.keepconn, ")")

mutable struct FCGIClient{T<:FCGISocket}
    addr::String
    csock::T
    nextreqid::UInt16
    processor::Union{Task,Nothing}
    requests::Dict{UInt16,FCGIRequest}
    lck::ReentrantLock
end

function FCGIClient(addr::String, csock::FCGISocket)
    client = FCGIClient(addr, csock, UInt16(0), nothing, Dict{UInt16,FCGIRequest}(), ReentrantLock())
    client.processor = @async process(client)
    client
end
FCGIClient(path::String) = FCGIClient(path, connect(path))
FCGIClient(ip::IPv4, port::Integer) = FCGIClient("$(ip):$(Int(port))", connect(ip, port))
show(io::IO, client::FCGIClient) = print(io, "FCGIClient(", client.addr, ", ", isopen(client.csock) ? "open" : "closed", ")")
close(client::FCGIClient) = close(client.csock)
function fcgiwrite(client::FCGIClient{T}, rec::FCGIRecord) where {T <: FCGISocket}
    lock(client.lck) do
        fcgiwrite(client.csock, rec)
    end
end
function requestdone(client::FCGIClient, reqid::UInt16)
    lock(client.lck) do
        if reqid in keys(client.requests)
            req = client.requests[reqid]
            delete!(client.requests, reqid)
            put!(req.isdone, nothing)
            req.keepconn || close(client)
        end
    end
end
function process(client::FCGIClient)
    try
        while isopen(client.csock)
            record = FCGIRecord(client.csock)
            reqid = requestid(record.header)
            if record.header.type == FCGIHeaderType.END_REQUEST
                requestdone(client, reqid)
            elseif record.header.type == FCGIHeaderType.STDERR
                req = client.requests[reqid]
                writefully(req.err, record.content)
            elseif record.header.type == FCGIHeaderType.STDOUT
                req = client.requests[reqid]
                writefully(req.out, record.content)
            else
                @warn("unexpected message received", reqid, type=record.header.type)
            end
        end
    finally
        for reqid in collect(keys(client.requests))
            requestdone(client, reqid)
        end
        close(client.csock)
    end
end

function process(client::FCGIClient, request::FCGIRequest)
    reqid = lock(client.lck) do
        client.nextreqid += UInt16(1)
        client.requests[client.nextreqid] = request
        client.nextreqid
    end
    # begin request
    fcgiwrite(client, FCGIRecord(FCGIHeaderType.BEGIN_REQUEST, reqid, FCGIBeginRequest(FCGIRequestRole.RESPONDER, request.keepconn ? KEEP_CONN : UInt8(0))))
    # send params
    fcgiwrite(client, FCGIRecord(FCGIHeaderType.PARAMS, reqid, FCGIParams(request.headers)))
    # send params end
    fcgiwrite(client, FCGIRecord(FCGIHeaderType.PARAMS, reqid, FCGIParams()))

    try
        # send stdin
        buffin = BufferedOutput() do bytes
            isempty(bytes) || fcgiwrite(client, FCGIRecord(FCGIHeaderType.STDIN, reqid, bytes))
        end
        while !eof(request.in)
            write(buffin, readavailable(request.in))
        end
        flush(buffin)
        close(buffin)
        # send stdin end
        fcgiwrite(client, FCGIRecord(FCGIHeaderType.STDIN, reqid, UInt8[]))
    catch ex
        request.exception = ex
    end

    request
end
