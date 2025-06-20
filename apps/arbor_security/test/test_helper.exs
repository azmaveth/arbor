# Configure the application to use mock databases in tests
Application.put_env(:arbor_security, :use_mock_db, true)

# Start ExUnit
ExUnit.start()
