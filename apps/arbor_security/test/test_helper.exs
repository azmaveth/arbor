# Configure the application to use mock databases in most tests
# Integration tests will override this by starting real repos
Application.put_env(:arbor_security, :use_mock_db, true)

# Start the real repository for integration tests that need it
# This will only be used if integration tests specifically start it
Application.ensure_all_started(:postgrex)

# Start ExUnit with integration test support
ExUnit.start(exclude: [:integration])
