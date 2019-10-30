struct BufferedPipe
    cascade::Pipe
    waiter::Task
    iob::IOBuffer
    lck::ReentrantLock

    function BufferedPipe(cascade::Pipe; delay::Float64=0.1, bytelimit::Int=1024*8)
        lck = ReentrantLock()
        iob = IOBuffer()
        waiter = @async begin
            while !_isinitialized(cascade)
                sleep(delay)
            end
            while isopen(cascade)
                timedwait(delay) do
                    lock(lck) do
                        position(iob) >= bytelimit
                    end
                end
                lock(lck) do
                    if position(iob) > 0
                        checkpoint = time()
                        write(cascade, take!(iob))
                    end
                end
            end
        end
        new(cascade, waiter, iob, lck)
    end
end

function write(buff::BufferedPipe, data)
    lock(buff.lck) do
        write(buff.iob, data)
    end
end

close(buff::BufferedPipe) = close(buff.cascade)
function flush(buff::BufferedPipe)
    lock(buff.lck) do
        if position(buff.iob) > 0
            write(buff.cascade, take!(buff.iob))
        end
    end
end

_isinitialized(x::Base.PipeEndpoint) = !(x.status == Base.StatusUninit || x.status == Base.StatusInit)
_isinitialized(x::Pipe) = _isinitialized(x.in) || _isinitialized(x.out)
