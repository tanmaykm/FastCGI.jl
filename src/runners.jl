abstract type Runner end

"""
Holds all the plumbing required for a running process or function
"""
struct Plumbing
    inp::Pipe                               # stdin
    out::Pipe                               # stdout
    err::Pipe                               # stderr

    function Plumbing()
        new(Pipe(), Pipe(), Pipe())
    end
end

function close(plumbing::Plumbing; inputendsonly::Bool=false)
    if inputendsonly
        close(plumbing.out.in)
        close(plumbing.err.in)
    else
        close(plumbing.inp)
        close(plumbing.out)
        close(plumbing.err)
    end
    nothing
end

function link(plumbing::Plumbing)
    Base.link_pipe!(plumbing.inp)
    Base.link_pipe!(plumbing.out)
    Base.link_pipe!(plumbing.err)
    nothing
end

"""
Runs fast CGI commands as processes. Holds the runner process and allows waiting and terminating the process.
"""
mutable struct ProcessRunner <: Runner
    process::Union{Base.Process,Nothing}    # launched process
    timeout::Int                            # time the process out after these many seconds
    timer::Union{Timer,Nothing}             # timer to kill the running process after timeout

    function ProcessRunner(timeout::Int=-1)
        new(nothing, timeout, nothing)
    end
end

function killproc(runner::ProcessRunner)
    if runner.process !== nothing
        try
            kill(runner.process)
        catch ex
            @warn("failed to kill process with SIGTERM, will issue SIGKILL")
            try
                kill(runner.process, Base.SIGKILL)
            catch ex
                @warn("failed to kill process with SIGKILL, abandoning")
            end
        end
        runner.process = nothing
    end
    closetimer(runner)
    nothing
end

function waitproc(runner::ProcessRunner)
    exitcode = 408
    try
        wait(runner.process)
        if runner.process !== nothing
            exitcode = runner.process.exitcode
        end
    catch ex
        @warn("exception waiting for process", ex)
    end
    runner.process = nothing
    closetimer(runner)
    exitcode
end

function launchproc(runner::ProcessRunner, plumbing::Plumbing, params::Dict{String,String})
    cmdpath = getcommand(params)
    @debug("launching command", cmdpath)
    if !isfile(cmdpath)
        err = "cmdpath not found: $cmdpath"
        @warn(err)
        return 404, err
    end
    try
        cmd = Cmd(`$cmdpath`; env=params)
        runner.process = run(pipeline(cmd, stdin=plumbing.inp, stdout=plumbing.out, stderr=plumbing.err), wait=false)
        setuptimer(runner, plumbing.out, plumbing.err)
        return 0, ""
    catch ex
        @warn("process exception", cmdpath, params, ex)
        return 500, "process exception"
    end
end

"""
Runs fast CGI commands as Julia functions. Holds the runner task and allows waiting and terminating (interrupting) the task.
"""
mutable struct FunctionRunner <: Runner
    process::Union{Task,Nothing}     # launched process
    timeout::Int                     # time the process out after these many seconds
    timer::Union{Timer,Nothing}      # timer to kill the running process after timeout

    function FunctionRunner(timeout::Int=-1)
        new(nothing, timeout, nothing)
    end
end

function killproc(runner::FunctionRunner)
    if (runner.process !== nothing) && !istaskdone(runner.process)
        try
            Base.throwto(runner.process, InterruptException())
        catch ex
            # ignore
        end
    end
    runner.process = nothing
    closetimer(runner)
    nothing
end

function waitproc(runner::FunctionRunner)
    result = 408
    try
        wait(runner.process)
        if runner.process !== nothing
            result = Int(fetch(runner.process))
        end
    catch ex
        # ignore (may have been interrupted)
        @warn("exception waiting for process", ex)
    end
    runner.process = nothing
    closetimer(runner)
    result
end

function launchproc(runner::FunctionRunner, plumbing::Plumbing, params::Dict{String,String})
    cmdpath = getcommand(params)
    @debug("launching command", cmdpath)

    cmd = try
        T = Main
        for t in split(cmdpath, ".")
            T = Base.eval(T, Symbol(t))
        end
        T::Function
    catch ex
        err = "Can not resolve $cmdpath"
        @warn(err, ex)
        return 404, err
    end
    try
        link(plumbing)
        runner.process = @async cmd(params, Base.pipe_reader(plumbing.inp), Base.pipe_writer(plumbing.out), Base.pipe_writer(plumbing.err))
        setuptimer(runner, Base.pipe_writer(plumbing.out), Base.pipe_writer(plumbing.err))
        return 0, ""
    catch ex
        @warn("process exception", cmdpath, params, ex)
        return 500, "process exception"
    end
end

function closetimer(runner::Union{ProcessRunner,FunctionRunner})
    if runner.timer !== nothing
        try
            close(runner.timer)
        catch ex
            @warn("exception closing timer", ex)
        end
        runner.timer = nothing
    end
    nothing
end

function setuptimer(runner::Union{ProcessRunner,FunctionRunner}, out, err)
    if runner.timeout > 0
        runner.timer = Timer(runner.timeout) do timer
            close(out)
            close(err)
            killproc(runner)
        end
    end
    nothing
end
