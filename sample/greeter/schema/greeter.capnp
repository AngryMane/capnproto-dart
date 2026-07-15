@0xd0aa9b7b6e99e748;

# Greeter schema demonstrating capability-passing between interfaces.

# A stateful session bound to a specific name.
interface GreetSession @0xb5f4a6c78d3e1029 {
  # Returns a greeting using the name bound to this session.
  greet @0 () -> (reply :Text);
}

interface Greeter @0xd41d8cd98f00b204 {
  # One-shot greeting.
  greet @0 (name :Text) -> (reply :Text);
  # Creates a session bound to [name]; the returned GreetSession capability
  # can be used to call greet() without repeating the name.
  newSession @1 (name :Text) -> (session :GreetSession);
}
