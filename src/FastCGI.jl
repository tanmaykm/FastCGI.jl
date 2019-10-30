module FastCGI

using Sockets

import Base: show, close, ==
export FCGIServer, process, stop

include("types.jl")
include("server.jl")
include("client.jl")

end # module
