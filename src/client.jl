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
