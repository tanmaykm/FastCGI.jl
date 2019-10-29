module FastCGI

using Sockets

import Base: show, ==

include("types.jl")
include("server.jl")
include("client.jl")

end # module
