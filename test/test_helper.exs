ExUnit.start()

# Exclude integration tests by default
ExUnit.configure(exclude: [integration: true])
