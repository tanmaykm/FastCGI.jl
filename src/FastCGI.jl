module FastCGI

using Sockets

import Base: show, close, write, flush, ==
export FCGIServer, process, stop

include("bufferedpipe.jl")
include("types.jl")
include("server.jl")
include("client.jl")

end # module
