struct BufferedOutput
    action::Function
    waiter::Task
    iob::IOBuffer
    lck::ReentrantLock

    function BufferedOutput(action::Function; delay::Float64=0.1, bytelimit::Int=1024*8)
        lck = ReentrantLock()
        iob = IOBuffer()
        waiter = @async begin
            while isopen(iob)
                timedwait(delay) do
                    lock(lck) do
                        position(iob) >= bytelimit
                    end
                end
                lock(lck) do
                    if position(iob) > 0
                        action(take!(iob))
                    end
                end
            end
        end
        new(action, waiter, iob, lck)
    end
end

function write(buff::BufferedOutput, data)
    lock(buff.lck) do
        write(buff.iob, data)
    end
end

close(buff::BufferedOutput) = close(buff.iob)
function flush(buff::BufferedOutput)
    lock(buff.lck) do
        if position(buff.iob) > 0
            (buff.action)(take!(buff.iob))
        end
    end
end
