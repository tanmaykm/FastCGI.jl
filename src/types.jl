# ref: http://www.mit.edu/~yandros/doc/specs/fcgi-spec.html

BYTE(x,n) = UInt8((x>>((n-1)*8))&0xff)
B16(b1::UInt8, b0::UInt8) = (UInt16(b1) << 8) | b0

function padding(x::T) where {T<:Integer}
    rem = x % T(8)
    (rem > T(0)) ? (T(8) - rem) : T(0)
end


function _readnvlen(io::T) where {T <: IO}
    b = read(io, UInt8)
    len = UInt32(b)
    if (b >> 7) !== UInt8(0)
        len = ((len & 0x7f) << 24) | (UInt32(read(io, UInt8)) << 16) | (UInt32(read(io, UInt8)) << 8) | read(io, UInt8)
    end
    len
end

function _writenvlen(io::I, l::T) where {I<:IO,T<:Integer}
    nbytes = 0
    if l > 0x7f
        l32 = UInt32(l)
        nbytes += write(io, BYTE(l32, 4) | 0x80)
        nbytes += write(io, BYTE(l32, 3))
        nbytes += write(io, BYTE(l32, 2))
        nbytes += write(io, BYTE(l32, 1))
    else
        nbytes += write(io, UInt8(l))
    end
    nbytes
end

#=
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
=#

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
function reqtypetostring(type::UInt8)
    (type === FCGIHeaderType.BEGIN_REQUEST) ? "BEGIN_REQUEST" :
    (type === FCGIHeaderType.ABORT_REQUEST) ? "ABORT_REQUEST" :
    (type === FCGIHeaderType.END_REQUEST) ? "END_REQUEST" :
    (type === FCGIHeaderType.PARAMS) ? "PARAMS" :
    (type === FCGIHeaderType.STDIN) ? "STDIN" :
    (type === FCGIHeaderType.STDOUT) ? "STDOUT" :
    (type === FCGIHeaderType.STDERR) ? "STDERR" :
    (type === FCGIHeaderType.DATA) ? "DATA" :
    (type === FCGIHeaderType.GET_VALUES) ? "GET_VALUES" :
    (type === FCGIHeaderType.GET_VALUES_RESULT) ? "GET_VALUES_RESULT" : "UNKNOWN"
end

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
    function FCGIHeader(type::UInt8, reqid::UInt16, contentlen::UInt16)
        new(VERSION_1, type, BYTE(reqid,2), BYTE(reqid,1), BYTE(contentlen,2), BYTE(contentlen,1), padding(contentlen))
    end
end
requestid(hdr::FCGIHeader) = B16(hdr.requestIdB1, hdr.requestIdB0)
contentlength(hdr::FCGIHeader) = B16(hdr.contentLengthB1, hdr.contentLengthB0)
show(io::IO, hdr::FCGIHeader) = print(io, "FCGIHeader(", reqtypetostring(hdr.type), ", id=", requestid(hdr), ", len=", contentlength(hdr), ")")

"""Mask for flags component of FCGIBeginRequest"""
const KEEP_CONN = UInt8(1)

"""Values for role component of FCGIBeginRequest"""
struct _FCGIRequestRole
    RESPONDER::UInt16
    AUTHORIZER::UInt16
    FILTER::UInt16
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
    function FCGIBeginRequest(role::UInt16, flags::UInt8=UInt8(0))
        new(BYTE(role,2), BYTE(role,1), flags)
    end
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
    function FCGIEndRequest(appstatus::UInt32, protocolstatus::UInt8=FCGIEndRequestProtocolStatus.REQUEST_COMPLETE)
        new(BYTE(appstatus,4), BYTE(appstatus,3), BYTE(appstatus,2), BYTE(appstatus,1), protocolstatus)
    end
end

# Variable names for FCGI_GET_VALUES / FCGI_GET_VALUES_RESULT records
"""The maximum number of concurrent transport connections this application will accept, e.g. "1" or "10"."""
const MAX_CONNS  = "FCGI_MAX_CONNS"
"""The maximum number of concurrent requests this application will accept, e.g. "1" or "50"."""
const MAX_REQS   = "FCGI_MAX_REQS"
"""If this application does not multiplex connections (i.e. handle concurrent requests over each connection) then "0", "1" otherwise."""
const MPXS_CONNS = "FCGI_MPXS_CONNS"

struct FCGIUnknownType
    type::UInt8
    # reserved::Vector{UInt8} # length 7
end
FCGIUnknownType(d::Vector{UInt8}) = FCGIUnknownType(d[1])

struct FCGINameValuePair
    name::String
    value::String
end
function FCGINameValuePair(io::T) where {T <: IO}
    lname = _readnvlen(io)
    lvalue = _readnvlen(io)
    name = _readstr(io, lname)
    value = _readstr(io, lvalue)
    FCGINameValuePair(name, value)
end

struct FCGIParams
    nvpairs::Vector{FCGINameValuePair}

    FCGIParams() = new(Vector{FCGINameValuePair}())
    FCGIParams(d::Vector{UInt8}) = FCGIParams(IOBuffer(d))
    function FCGIParams(io::T) where {T <: IO}
        nvpairs = Vector{FCGINameValuePair}()
        while !eof(io)
            push!(nvpairs, FCGINameValuePair(io))
        end
        new(nvpairs)
    end
end

struct FCGIRecord
    header::FCGIHeader
    content::Vector{UInt8}

    function FCGIRecord(io::T) where {T <: IO}
        header = FCGIHeader(io)
        content = _readbytes(io, contentlength(header))
        _ = _readbytes(io, header.paddingLength) # discard padding
        new(header, content)
    end
    function FCGIRecord(type::UInt8, reqid::UInt16, content::Vector{UInt8})
        contentlen = UInt16(length(content))
        new(FCGIHeader(type, reqid, contentlen), content)
    end
    FCGIRecord(type::UInt8, reqid::UInt16, content::String) = FCGIRecord(type, reqid, convert(Vector{UInt8},codeunits(content)))
    function FCGIRecord(type::UInt8, reqid::UInt16, content::Union{FCGIBeginRequest,FCGIEndRequest,FCGIParams,FCGIUnknownType})
        iob = IOBuffer()
        fcgiwrite(iob, content)
        FCGIRecord(type, reqid, take!(iob))
    end
end
show(io::IO, rec::FCGIRecord) = print(io, "FCGIRecord(", reqtypetostring(rec.header.type), ", id=", requestid(rec.header), ", len=", contentlength(rec.header), ")")

fcgiwrite(io::T, hdr::FCGIHeader) where {T<:IO} = write(io, hdr.version, hdr.type, hdr.requestIdB1, hdr.requestIdB0, hdr.contentLengthB1, hdr.contentLengthB0, hdr.paddingLength, UInt8(0))
fcgiwrite(io::T, begreq::FCGIBeginRequest) where {T<:IO} = write(io, begreq.roleB1, begreq.roleB0, begreq.flags, zeros(UInt8, 5))
fcgiwrite(io::T, endreq::FCGIEndRequest) where {T<:IO} = write(io, endreq.appStatusB3, endreq.appStatusB2, endreq.appStatusB1, endreq.appStatusB0, endreq.protocolStatus, zeros(UInt8, 3))
fcgiwrite(io::T, unk::FCGIUnknownType) where {T<:IO} = write(io, unk.type, zeros(UInt8, 7))
function fcgiwrite(io::T, nv::FCGINameValuePair) where {T<:IO}
    nbytes = 0
    lname = length(nv.name)
    lvalue = length(nv.value)
    nbytes += _writenvlen(io, lname)
    nbytes += _writenvlen(io, lvalue)
    nbytes += write(io, nv.name, nv.value)
    nbytes
end
fcgiwrite(io::T, params::FCGIParams) where {T<:IO} = sum([fcgiwrite(io, nv) for nv in params.nvpairs])
function fcgiwrite(io::T, rec::FCGIRecord) where {T<:IO}
    nbytes = fcgiwrite(io, rec.header)
    nbytes += write(io, rec.content)
    if rec.header.paddingLength > 0
        nbytes += write(io, zeros(UInt8, rec.header.paddingLength))
    end
    nbytes
end

const FCGIMsgComponent = Union{FCGIBeginRequest, FCGIEndRequest, FCGIUnknownType, FCGINameValuePair, FCGIParams, FCGIRecord}
function ==(o1::T, o2::T) where {T <: FCGIMsgComponent}
    for fld in fieldnames(T)
        (getfield(o1, fld) == getfield(o2, fld)) || (return false)
    end
    true
end
