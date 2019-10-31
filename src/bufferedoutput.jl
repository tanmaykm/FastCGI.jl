const MAX_WRITE_SIZE = Int(typemax(UInt16))
struct BufferedOutput
    action::Function
    waiter::Task
    iob::IOBuffer
    lck::ReentrantLock

    function BufferedOutput(action::Function; delay::Float64=0.05, bytelimit::Int=1024*8, maxbuff::Int=MAX_WRITE_SIZE)
        lck = ReentrantLock()
        iob = IOBuffer(;maxsize=maxbuff)
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
    towrite = length(data)
    pos = 1
    while pos <= towrite
        (pos == 1) || sleep(0.05)
        endpos = min(pos+buff.iob.maxsize-1, towrite)
        pos += lock(buff.lck) do
            write(buff.iob, view(data, pos:endpos))
        end
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
