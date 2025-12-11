
steps to produce an amzn-corretto container:
1. Build the container using this branch via: `docker build . -t andris/mc-dev:v5` execute this in the root of the repo!
2. create or use an example docker compose and change `image: itzg/minecraft-server:latest` -> `image: andris/mc-dev:v5`
3. bring the container up with `docker compose up`


if anything breaks I take 0 responsibility and you can figure it out I belive in you :)


[![Documentation Status](https://readthedocs.org/projects/docker-minecraft-server/badge/?version=latest)](https://docker-minecraft-server.readthedocs.io/en/latest/?badge=latest)

 [![Read the docs](docs/img/docs-banner.png)](https://docker-minecraft-server.readthedocs.io/)

There you will find things like
- [Quick start with Docker Compose](https://docker-minecraft-server.readthedocs.io/en/latest/#using-docker-compose)
- Running [different versions of Minecraft](https://docker-minecraft-server.readthedocs.io/en/latest/versions/minecraft/) and using [various server types](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/) for Java Edition
- [Setting server properties via container environment variables](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)
- [Managing mods and plugins with automated downloads and cleanup](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)
- [Using various modpack providers/platforms](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/)
- ...and much more

There are also many examples located in [the examples directory](examples) of this repo.

This image only supports Java edition natively; however, if looking for a server that is compatible with Bedrock edition, then use [itzg/minecraft-bedrock-server](https://github.com/itzg/docker-minecraft-bedrock-server) or [refer to this section](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/#bedrock-compatible-server) to add Bedrock compatibility to a Java edition server.
