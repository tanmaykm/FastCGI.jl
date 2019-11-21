using FastCGI
using Test
using Random
using Sockets

const NLOOPS = 10
const STATS = Dict{String, Any}()

function test_types()
    @testset "utility methods" begin
        @test FastCGI.BYTE(0x0102, 1) === 0x02
        @test FastCGI.BYTE(0x0102, 2) === 0x01
        @test FastCGI.B16(0x02, 0x03) === 0x0203
        @test FastCGI.padding(7) == 1
        @test FastCGI.padding(8) == 0
        @test FastCGI.padding(17) == 7
    end

    @testset "read-write nv lengths" begin
        p = PipeBuffer()
        @test FastCGI._writenvlen(p, UInt8(5)) == 1
        @test FastCGI._readnvlen(p) === UInt32(5)
        @test FastCGI._writenvlen(p, UInt16(127)) == 1
        @test FastCGI._readnvlen(p) === UInt32(127)
        @test FastCGI._writenvlen(p, UInt16(128)) == 4
        @test FastCGI._readnvlen(p) === UInt32(128)
        @test FastCGI._writenvlen(p, UInt16(1024)) == 4
        @test FastCGI._readnvlen(p) === UInt32(1024)
    end

    @testset "read-write types" begin
        p = PipeBuffer()
        reqid = UInt16(1)

        # FCGIBeginRequest
        req = FastCGI.FCGIBeginRequest(FastCGI.FCGIRequestRole.RESPONDER, FastCGI.KEEP_CONN)
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.BEGIN_REQUEST, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 16
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)

        # FCGIEndRequest
        req = FastCGI.FCGIEndRequest(UInt32(10), FastCGI.FCGIEndRequestProtocolStatus.REQUEST_COMPLETE)
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.END_REQUEST, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 16
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)

        # FCGIUnknownType
        req = FastCGI.FCGIUnknownType(UInt8(20))
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.END_REQUEST, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 16
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)

        # FCGIParams
        req = FastCGI.FCGIParams()
        push!(req.nvpairs, FastCGI.FCGINameValuePair("name1", "value1"))
        push!(req.nvpairs, FastCGI.FCGINameValuePair("name2", ""))
        push!(req.nvpairs, FastCGI.FCGINameValuePair("name1", randstring(512)))
        push!(req.nvpairs, FastCGI.FCGINameValuePair(randstring(512), randstring(1024)))
        rec = FastCGI.FCGIRecord(FastCGI.FCGIHeaderType.GET_VALUES, reqid, req)
        @test FastCGI.fcgiwrite(p, rec) == 2096
        @test FastCGI.FCGIRecord(p) == rec
        reqid += UInt16(1)
    end
end

function test_bufferedoutput()
    @testset "buffered output" begin
        out = IOBuffer()
        buffout = FastCGI.BufferedOutput((data)->write(out,data); delay=5.0, bytelimit=10)
        bytes = UInt8[1,2,3,4,5]
        write(buffout, bytes)
        sleep(1)
        @test position(out) == 0
        write(buffout, bytes)
        sleep(1)
        @test position(out) == 10
        write(buffout, bytes)
        sleep(1)
        @test position(out) == 10
        sleep(5)
        @test position(out) == 15
        write(buffout, bytes)
        flush(buffout)
        sleep(1)
        @test position(out) == 20
        close(buffout)
        @test !isopen(buffout.iob)
        sleep(6)
        @test istaskdone(buffout.waiter)
    end
end

function test_clientserver()
    @testset "client-server" begin
        @testset "Unix Domain Socket" begin
            testdir = dirname(@__FILE__)
            socket = joinpath(testdir, "fcgi.socket")

            # start server
            server = FCGIServer(socket)
            @show server
            set_server_runner(FastCGI.ProcessRunner)
            set_server_param("FCGI_MAX_CONNS", "200")
            servertask = @async process(server)
            @test issocket(socket)
            @test isrunning(server)

            # run client
            client = FCGIClient(socket)
            @show client
            headers = Dict("DOCUMENT_ROOT"=>testdir, "SCRIPT_NAME"=>"/hello.sh")
            do_requests(client, headers, "ProcessRunner over Unix Domain Sockets")

            # close
            close(client)
            stop(server)
            @test !isrunning(client)
            @test !isrunning(server)
        end
        @testset "TCP Socket" begin
            testdir = dirname(@__FILE__)
            host = ip"127.0.0.1"
            port = 8989

            # start server
            server = FCGIServer(host, port)
            servertask = @async process(server)
            @test isa(server.lsock, Sockets.TCPServer)
            @test isrunning(server)

            # run client
            client = FCGIClient(host, port)
            headers = Dict("DOCUMENT_ROOT"=>testdir, "SCRIPT_NAME"=>"hello.sh")
            do_requests(client, headers, "ProcessRunner over TCP Sockets")

            # close
            close(client)
            stop(server)
            @test !isrunning(client)
            @test !isrunning(server)
        end
    end
end

function testrunner(params, in, out, err)
    println(out, """Content-type: text/html

<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<title>Hello World</title>
</head>
<body>
Hello World
<pre>
""")
    for (n,v) in params
        println(out, "$n = $v")
    end
    for (n,v) in ENV
        println(out, "$n = $v")
    end
    println(out, """
</pre>
</body>
</html>
""")

    flush(out)   
    close(out)
    close(err) 
    return 0
end

function test_functionrunner()
    @testset "Function Runner" begin
        testdir = dirname(@__FILE__)
        socket = joinpath(testdir, "fcgi.socket")

        # start server
        server = FCGIServer(socket)
        @show server
        set_server_runner(FastCGI.FunctionRunner)
        set_server_param("FCGI_MAX_CONNS", "200")
        servertask = @async process(server)
        @test issocket(socket)
        @test isrunning(server)

        # run client
        client = FCGIClient(socket)
        @show client
        headers = Dict("SCRIPT_FILENAME"=>"testrunner")
        do_requests(client, headers, "FunctionRunner over Unix Domain Sockets")

        # close
        close(client)
        stop(server)
        @test !isrunning(client)
        @test !isrunning(server)
    end
end

function do_requests(client, headers, statname)
    STATS[statname] = @timed for idx in 1:NLOOPS
        request = FCGIRequest(; headers=headers, keepconn=true)
        process(client, request)
        @test isrunning(client)
        wait(request.isdone)
        @test isempty(take!(request.err))
        response = take!(request.out)
        @test length(response) > 0
    end
end

test_bufferedoutput()
test_types()
test_clientserver()
test_functionrunner()

println("Times for $NLOOPS requests:")
for (n,v) in STATS
    println(n, ": ", v[2], " sec")
end
