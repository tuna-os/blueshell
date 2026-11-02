# Surface worker boundaries

`Surface` is owned by the app thread. It initializes the renderer and IO
worker state at stable addresses, then starts their dedicated OS threads;
search is started lazily for a nonempty needle. These are not interchangeable
pool jobs: each worker owns an event loop and has different state and messages.
`WorkerLifecycle` tracks whether each thread has been spawned and joined; it is
owner-thread-only, and `running` does not guarantee the worker has not already
exited. A failed spawn leaves it initialized. On any later surface-init failure,
started workers are stopped and joined before shared state is destroyed.
Search spawn failure also clears the optional search state.

## Communication

| Boundary | Protocol and ownership |
| --- | --- |
| Producers → renderer | `renderer.Message` on the bounded `renderer.Thread.Mailbox`; producers notify `wakeup`. Search callbacks also send directly to this mailbox. |
| Surface / terminal producers → IO | `termio.Message` through `Termio.queueMessage` and `termio.Mailbox`; the mailbox owns queued messages, and its consumer drains or deinits them. |
| Surface → search | `search.Thread.Message` on its bounded mailbox, followed by `wakeup`; search owns its search state. |
| Search → renderer / surface | `search.Thread.Event` callback runs on the search thread. It copies highlights into renderer messages and posts selected/total values via the surface mailbox. |
| Renderer / IO → app or surface | App and surface mailboxes marshal actions back to the app thread. |
| IO → renderer | IO also holds the renderer mailbox and wakeup handle; coordination is not exclusively through Surface. |

The queues can block when full. In particular, IO mailbox send can temporarily
release and reacquire the renderer mutex when called with `.locked`; callers
must not assume state is unchanged across that operation. Renderer, IO,
search, and Surface share the terminal and other `renderer.State` members under
`renderer.State.mutex` (see that type for its demand/handoff rules). This mutex
is not a mailbox and does not protect the `State` object itself. Search callback
code must only access immutable Surface fields or thread-safe mailboxes.

## Shutdown constraints

The owner must not hold the shared renderer mutex while stopping or joining a
worker. Search is stopped and joined first because its quit callback sends to the
renderer; renderer is joined next, then IO, preserving the existing shutdown
order. Only after all joins may Surface destroy the worker state, renderer, IO,
mutex, and terminal. Search can also be stopped independently by the app thread.
A stop notification failure is logged and the join is still required for safety;
it can stall. Mailbox back-pressure and shutdown ordering remain important when
changing these protocols.

This lifecycle wrapper does not replace the existing mutex with a guard or
redesign the mailboxes and their back-pressure. Those changes require a separate
migration of the many existing producers and lock-sensitive call sites.
