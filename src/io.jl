function process_incoming(io::T, chan::Channel{FCGIRecord}) where {T <: IO}
    try
        while !eof(io)
            rec = FCGIRecord(io)
            put!(chan, rec)
        end
    catch ex
        eof(io) || rethrow(ex)
    end
end
