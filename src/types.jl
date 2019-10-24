# ref: http://www.mit.edu/~yandros/doc/specs/fcgi-spec.html

BYTE(x,n) = UInt8((x>>((n-1)*8))&0xff)
B16(b1::UInt8, b0::UInt8) = (UInt16(b1) << 8) | b0

function _readnvlen(io::T) where {T <: IO}
    b = read(io, UInt8)
    len = UInt32(b)
    if (b >> 7) !== UInt8(0)
        len = ((len & 0x7f) << 24) | (UInt32(read(io, UInt8)) << 16) | (UInt32(read(io, UInt8)) << 8) | read(io, UInt8)
    end
    len
end

function _readnvlen(d::Vector{UInt8}, pos::Int)
    len = UInt32(d[pos])
    pos += 1
    if (len >> 7) !== 0
        len = ((len & 0x7f) << 24)
        pos += 1
        len |= (UInt32(d[pos]) << 16)
        pos += 1
        len |= (UInt32(d[pos]) << 8)
        pos += 1
        len |= UInt32(d[pos])
    end
    len, pos
end

function _readbytes(io::I, len::T) where {I<:IO, T<:Integer}
    @assert len >= 0
    (len == 0) && (return UInt8[])
    buff = read(io, len)
    while length(buff) != len
        append!(buff, read(io, (len - length(buff))))
    end
    buff
end
_readstr(io::I, len::T) where {I<:IO, T<:Integer} = String(_readbytes(io, len))

"""Listening socket file number"""
const LISTENSOCK_FILENO = 0
const MAX_LENGTH = 0xffff

"""Number of bytes in a FCGIHeader.  Future versions of the protocol will not reduce this number."""
const HEADER_LEN = UInt8(8)

"""Value for version component of FCGIHeader"""
const VERSION_1 = UInt8(1)

"""Value for requestId component of FCGIHeader"""
const NULL_REQUEST_ID = 0

"""Values for type component of FCGIHeader"""
struct _FCGIHeaderType
    BEGIN_REQUEST::UInt8        # FCGIBeginRequest
    ABORT_REQUEST::UInt8        # not applicable
    END_REQUEST::UInt8          # FCGIEndRequest
    PARAMS::UInt8               # FCGIParams
    STDIN::UInt8                # FCGIRecord.content
    STDOUT::UInt8               # FCGIRecord.content
    STDERR::UInt8               # FCGIRecord.content
    DATA::UInt8                 # FCGIRecord.content (applicable only in context of filters)
    GET_VALUES::UInt8           # FCGIParams with empty values
    GET_VALUES_RESULT::UInt8    # FCGIParams
    UNKNOWN_TYPE::UInt8         # FCGIUnknownType
    MAXTYPE::UInt8
    function _FCGIHeaderType()
        new(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 11)
    end
end
const FCGIHeaderType = _FCGIHeaderType()

struct FCGIHeader
    version::UInt8
    type::UInt8
    requestIdB1::UInt8
    requestIdB0::UInt8
    contentLengthB1::UInt8
    contentLengthB0::UInt8
    paddingLength::UInt8
    # reserved::UInt8

    FCGIHeader(io::T) where {T <: IO} = FCGIHeader(read(io, UInt64))
    FCGIHeader(b::UInt64) = new(BYTE(b,1), BYTE(b,2), BYTE(b,3), BYTE(b,4), BYTE(b,5), BYTE(b,6), BYTE(b,7))
end
requestid(hdr::FCGIHeader) = B16(hdr.requestIdB1, hdr.requestIdB0)
contentlength(hdr::FCGIHeader) = B16(hdr.contentLengthB1, hdr.contentLengthB0)

struct FCGIRecord
    header::FCGIHeader
    content::Vector{UInt8}

    function FCGIRecord(io::T) where {T <: IO}
        @info("reading header")
        header = FCGIHeader(io)
        @info("reading record", type=header.type, contentlength=contentlength(header))
        content = _readbytes(io, contentlength(header))
        _ = _readbytes(io, header.paddingLength) # discard padding
        new(header, content)
    end
end

"""Mask for flags component of FCGIBeginRequest"""
const KEEP_CONN = UInt8(1)

"""Values for role component of FCGIBeginRequest"""
struct _FCGIRequestRole
    RESPONDER::UInt8
    AUTHORIZER::UInt8
    FILTER::UInt8
    function _FCGIRequestRole()
        new(1, 2, 3)
    end
end
const FCGIRequestRole = _FCGIRequestRole()

struct FCGIBeginRequest
    roleB1::UInt8
    roleB0::UInt8
    flags::UInt8
    # reserved::Vector{UInt8} # length 5
    FCGIBeginRequest(d::Vector{UInt8}) = new(d[1], d[2], d[3])
end
role(req::FCGIBeginRequest) = B16(req.roleB1, req.roleB0)
keepconn(req::FCGIBeginRequest) = (req.flags & KEEP_CONN) != 0x00

"""Values for protocolStatus component of FCGIEndRequest"""
struct _FCGIEndRequestProtocolStatus
    REQUEST_COMPLETE::UInt8
    CANT_MPX_CONN::UInt8
    OVERLOADED::UInt8
    UNKNOWN_ROLE::UInt8
    function _FCGIEndRequestProtocolStatus()
        new(0, 1, 2, 3)
    end
end
const FCGIEndRequestProtocolStatus = _FCGIEndRequestProtocolStatus()

struct FCGIEndRequest
    appStatusB3::UInt8
    appStatusB2::UInt8
    appStatusB1::UInt8
    appStatusB0::UInt8
    protocolStatus::UInt8
    # reserved::Vector{UInt8} # length 3
    FCGIEndRequest(d::Vector{UInt8}) = new(d[1], d[2], d[3], d[4], d[5])
end

"""Variable names for FCGI_GET_VALUES / FCGI_GET_VALUES_RESULT records"""
const MAX_CONNS  = "FCGI_MAX_CONNS"
const MAX_REQS   = "FCGI_MAX_REQS"
const MPXS_CONNS = "FCGI_MPXS_CONNS"

struct FCGIUnknownType
    type::UInt8
    # reserved::Vector{UInt8} # length 7
    FCGIEndRequest(d::Vector{UInt8}) = new(d[1])
end

struct FCGINameValuePair
    name::String
    value::String

    function FCGINameValuePair(io::T) where {T <: IO}
        lname = _readnvlen(io)
        lvalue = _readnvlen(io)
        name = _readstr(io, lname)
        value = _readstr(io, lvalue)
        new(name, value)
    end
end

struct FCGIParams
    nvpairs::Vector{FCGINameValuePair}

    FCGIParams(d::Vector{UInt8}) = FCGIParams(IOBuffer(d))
    function FCGIParams(io::T) where {T <: IO}
        nvpairs = Vector{FCGINameValuePair}()
        while !eof(io)
            push!(nvpairs, FCGINameValuePair(io))
        end
        new(nvpairs)
    end
end
