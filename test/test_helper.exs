ExUnit.start(assert_receive_timeout: 2_000, refute_receive_timeout: 50)

cleanup = Oban.QuackDB.TestServer.start()

ExUnit.after_suite(fn _result -> Oban.QuackDB.TestServer.stop(cleanup) end)
