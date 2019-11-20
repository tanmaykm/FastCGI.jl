module FastCGI

using Sockets

import Base: show, close, write, flush, ==
export FCGIServer, FCGIClient, FCGIRequest, process, isrunning, stop, set_server_param, set_server_runner

include("bufferedoutput.jl")
include("types.jl")
include("processhandler.jl")
include("server.jl")
include("client.jl")

end # module
