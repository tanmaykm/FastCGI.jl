module FastCGI

using Sockets

import Base: show, close, write, flush, ==
export FCGIServer, FCGIClient, FCGIRequest, process, stop, set_server_param

include("bufferedoutput.jl")
include("types.jl")
include("server.jl")
include("client.jl")

end # module
