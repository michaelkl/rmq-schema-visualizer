# RabbitMQ schema visualizer

It's a simple Ruby script that converts your imported RabbitMQ schema definition JSON
file into DOT file you can use to visualize it.

## Features
* Generates a diagram in Graphviz format
* Displays exchanges, queues and bindings
* Displays dead letter exchanges bindings
* Displays routing keys
* For queues, displays some common configuration parameters
* Split into subgraphs based on vhost for more structured view

## Installation

```
gem install ruby-graphviz
```

## Usage
```
ruby rmq-schema-visualizer.rb --format pdf --outpout schema.pdf rabbit_rabbitmq.local_2024-3-13.json
```

Grapviz supports a great variety of format including but not limited to:
* png
* jpg
* pdf
* svg
* ps
* dot
