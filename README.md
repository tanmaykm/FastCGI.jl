# FastCGI.jl

[![Build Status](https://travis-ci.org/tanmaykm/FastCGI.jl.png)](https://travis-ci.org/tanmaykm/FastCGI.jl)

[![Coverage Status](https://coveralls.io/repos/github/tanmaykm/FastCGI.jl/badge.svg?branch=master)](https://coveralls.io/github/tanmaykm/FastCGI.jl?branch=master)

FastCGI is a binary protocol for interfacing interactive programs with a web server. It is a variation on the earlier Common Gateway Interface (CGI). FastCGI's main aim is to reduce the overhead related to interfacing between web server and CGI programs, allowing a server to handle more web page requests per unit of time.

FastCGI Specification: <http://www.mit.edu/~yandros/doc/specs/fcgi-spec.html>

FastCGI.jl is a package that implements a Julia FastCGI client and server. Additionally, it allows Julia functions to be used to respond directly to requests, which can be significantly faster and more efficient.

## Examples:

### Using the server

```julia
julia> using FastCGI

julia> server = FCGIServer("/var/run/fcgi/fcgi.socket")
FCGIServer(/var/run/fcgi/fcgi.socket, open)

julia> process(server)
┌ Info: processing
│   SCRIPT_FILENAME = "..."
└   SCRIPT_NAME = "..."
...
```

### Using the client

```julia
julia> using FastCGI

julia> client = FCGIClient("/var/run/fcgi/fcgi.socket")
FCGIClient(/var/run/fcgi/fcgi.socket, open)

julia> headers = Dict("SCRIPT_FILENAME"=>"/fcgihome/hello.sh");

julia> request = FCGIRequest(; headers=headers)
FCGIRequest(complete=false, keepconn=false)

julia> process(client, request);

julia> wait(request.isdone)

julia> response = String(take!(request.out));
```

### Hooking up Julia functions

FastCGI.jl server allows you to hook up a Julia function as a responder, instead of having to spawn an external process. This is much more efficient and fast. This can be an easy way to hook up a Julia backend to existing web servers like [Nginx](https://www.nginx.com/), [Apache](https://httpd.apache.org/) or [others](https://en.wikipedia.org/wiki/FastCGI#Web_servers_that_implement_FastCGI).

To enable this mode, switch the runner to `FastCGI.FunctionRunner`:

```julia
FastCGI.set_server_runner(FastCGI.FunctionRunner)
```

Define the method that would respond to requests:

```julia
function fastcgi_responder(params, in, out, err)
    # params: a Dict{String,String} with all fastcgi request parameters
    # in: input stream to be read from
    # out: output stream to write response to
    # err: error stream to write errors to

    # return the exit code that needs to be sent as the response
    return 0
end
```

Send requests as usual, ensuring that the `SCRIPT_FILENAME` parameter in requests contains the fully qualified function name to invoke.

### Handling Timeouts

There is no timeout imposed on the scripts by default. But a fixed timeout can be imposed on the scripts by configuring the `Runner` appropriately.

```julia
# set up a FunctionRunner with 10 second timeout
FastCGI.set_server_runner(()->FastCGI.FunctionRunner(10))

# set up a ProcessRunner with 5 second timeout
FastCGI.set_server_runner(()->FastCGI.ProcessRunner(5))
```

The server will terminate requests running longer than the timeout configured. A response code of 408 (Request Timeout) will be returned.
