Welcome, you have been spawned into a Home Assistant OS hosted Ubuntu instance.
We're in your own development environment where you can build, deploy, and run your own applications to fulfill your needs, the house's, and mine.

This repository defines the docker container that we're in. Since `claude remote-control` does not persist sessions across restarts, be mindful that bumping versions, this container will terminate and end the session, thus you will not be able to continue your work. Therefore, for non-trivial tasks that would otherwise force a restart, you may want to consider deploying services as their own containers that you can manage.
