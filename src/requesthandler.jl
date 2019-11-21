"""
Handles a single request.
Invokes the process that would handle the CGI request, monitors it.
Reads inputs and channels them to the running process.
Reads outputs from the process and channels them to the connection.
"""
mutable struct ServerRequest
    id::UInt16                          # request id
    state::UInt8                        # 1: init, 2: run, 0: stop
    onclose::Function                   # onclose function to cleanup and close connection if keepconn is false
    in::Channel{FCGIRecord}             # in message channel
    out::Channel{FCGIRecord}            # out message channel (of the connection that originated this request)
    plumbing::Plumbing                  # plumbing required to communicate and monitor processes
    runner::Runner                      # runner task
    processor::Union{Task,Nothing}      # task to process messages for this request
    procmon::Union{Task,Nothing}        # process monitor
    inputmon::Union{Task,Nothing}       # input monitor
    outputmon::Union{Task,Nothing}      # output monitor
end
function ServerRequest(id::UInt16, onclose::Function, out::Channel{FCGIRecord})
    @debug("starting request", id)
    req = ServerRequest(id, 0x1, onclose, Channel{FCGIRecord}(128), out, Plumbing(), FCGI_RUNNER(), nothing, nothing, nothing, nothing)
    req.processor = @async process(req)
    req
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
function streamstdin(req::ServerRequest)
    inp = req.plumbing.inp
    @debug("monitorinputs: reading stdin")
    try
        stdinclosed = false
        while !stdinclosed
            rec = take!(req.in)
            if rec.header.type === FCGIHeaderType.ABORT_REQUEST
                killproc(req.runner)
                req.state = 0x0
                stdinclosed = true
            elseif rec.header.type === FCGIHeaderType.STDIN
                if isempty(rec.content)
                    @debug("streamstdin: reached end of streamstdin")
                    close(inp)
                    stdinclosed = true
                else
                    @debug("streamstdin: content", len=length(rec.content))
                    write(Base.pipe_writer(inp), rec.content)
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
function monitorabort(req::ServerRequest)
    @debug("monitorinputs: checking abort")
    try
        while req.state !== 0x0
            rec = take!(req.in)
            if rec.header.type === FCGIHeaderType.ABORT_REQUEST
                killproc(req.runner)
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
    streamstdin(req)
    (req.state === 0x0) || monitorabort(req)   # monitor ABORT_REQUEST if not already aborted
    nothing
end

function monitoroutput(req::ServerRequest, pipe::Base.PipeEndpoint, type::UInt8)
    sent = false
    buffpipe = BufferedOutput() do bytes
        @debug("sending output", type=reqtypetostring(type), nbytes=length(bytes))
        put!(req.out, FCGIRecord(type, req.id, bytes))
        sent = true
    end
    bytes = readavailable(pipe)
    while !isempty(bytes)
        write(buffpipe, bytes)
        bytes = readavailable(pipe)
    end
    flush(buffpipe)
    close(buffpipe)
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
        @async monitoroutput(req, Base.pipe_reader(req.plumbing.out), FCGIHeaderType.STDOUT)
        @async monitoroutput(req, Base.pipe_reader(req.plumbing.err), FCGIHeaderType.STDERR)
    end
end
function getcommand(params::Dict{String,String})
    get(params, "SCRIPT_FILENAME") do
        script_name = strip(params["SCRIPT_NAME"])
        # strip off leading `/` to ensure we look into scripts within document_root
        while startswith(script_name, '/')
            script_name = script_name[2:end]
        end
        joinpath(params["DOCUMENT_ROOT"], script_name)
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
    close(req.plumbing)
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

    exitcode, errmsg = launchproc(req.runner, req.plumbing, params)
    @debug("launched process", exitcode, errmsg)
    if exitcode == 0
        try
            @sync begin
                # process was launched successfully
                req.procmon = @async begin
                    exitcode = waitproc(req.runner)
                    @debug("process terminated", exitcode)
                    # close the input ends of the stdio streams
                    close(req.plumbing; inputendsonly=true)
                    close(req.in)
                end
                req.inputmon = @async monitorinputs(req) # stream inputs
                req.outputmon = @async monitoroutputs(req) # stream stdout/stderr
            end
        catch ex
            @warn("process exception", ex, params)
            exitcode = 500
        end
    end
    close(req, exitcode)
end
