require 'json'
require 'getoptlong'
require 'delegate'
require "graphviz"

# Encloses RabbitMQ Queue information
RmqQueue = Struct.new(:name, :vhost, :durable, :auto_delete, :arguments, :sort_order, keyword_init: true) do
  include Comparable

  attr_accessor :node

  def initialize(*args, **kwargs)
    super
    self.sort_order ||= 0
  end

  def self.from_json(d)
    new(**d)
  end

  def <=>(other)
    [self.vhost, self.sort_order, self.class.name, self.name] <=> [other.vhost, other.sort_order, other.name, other.class.name]
  end

  def full_name
    "#{vhost.delete_suffix('/')}/#{name}".delete_prefix('/')
  end

  def durable?
    self.durable == true
  end

  def auto_delete?
    self.auto_delete == true
  end

  def dlx?
    self.arguments['x-dead-letter-exchange'] && !self.arguments['x-dead-letter-exchange'].empty?
  end
end


# Encloses RabbitMQ Exchange information
RmqExchange = Struct.new(:name, :vhost, :type, :durable, :auto_delete, :internal, :arguments, :sort_order, keyword_init: true) do
  include Comparable

  attr_accessor :node

  def initialize(*args, **kwargs)
    super
    self.sort_order ||= 0
  end

  def self.from_json(d)
    new(**d)
  end

  def <=>(other)
    [self.vhost, self.sort_order, self.class.name, self.name] <=> [other.vhost, other.sort_order, other.name, other.class.name]
  end

  def full_name
    "#{vhost.delete_suffix('/')}/#{name}".delete_prefix('/')
  end

  def durable?
    self.durable == true
  end

  def auto_delete?
    self.auto_delete == true
  end

  def internal?
    self.internal== true
  end
end


# Encloses RabbitMQ Binding information
RmqBinding = Struct.new(:source, :vhost, :destination, :routing_key, :dsx, :arguments, keyword_init: true) do
  def dsx?
    self.dsx == true
  end
end


# Decorates queue or exchange for visualization representation
class NodeDecorator < SimpleDelegator
  def to_s
    case __getobj__
    when RmqQueue
      name_components = ["<B>Q: #{full_name}</B>"]
      if arguments
        args = arguments.slice(*%w[x-max-priority x-queue-type x-expires x-message-ttl x-max-length])
        name_components.concat(args.map{ "#{_1}: #{_2}" })
      end
      "< " + name_components.join("<BR/>") + ">"

    when RmqExchange
      "< <B>E: #{full_name}</B><BR/>#{type.upcase}>"
    end
  end

  def add_to_graph(g)
    case __getobj__
    when RmqQueue
      self.node = g.add_nodes(to_s, shape: 'box', style: "solid,filled", fillcolor: '#DAE8FC')

    when RmqExchange
      line_style = internal? ? 'dashed' : 'solid'
      self.node = g.add_nodes(to_s, shape: 'box', style: "#{line_style},rounded,filled", fillcolor: '#F8CECC')
    end
  end
end


# Decorates binding for visualization representation
class EdgeDecorator < SimpleDelegator
  def label
    routing_key || ''
  end

  def add_to_graph(g)
    if dsx?
      g.add_edges(source.node, destination.node, label: label, color: 'red')
    else
      g.add_edges(source.node, destination.node, label: label)
    end
  end
end

#####

def read_arguments
  options = GetoptLong.new(
    ['--format', '-f', GetoptLong::REQUIRED_ARGUMENT],
    ['--output', '-o', GetoptLong::REQUIRED_ARGUMENT],
    ['--order-first', GetoptLong::REQUIRED_ARGUMENT],
    ['--order-last', GetoptLong::REQUIRED_ARGUMENT]
  )

  @output_file = nil
  @output_format = 'dot'
  @order_first = {}
  @order_last = {}
  options.each do |option, argument|
    case option
    when '--format'
      @output_format = argument.downcase
    when '--output'
      @output_file = argument
    when '--order-first'
      # give then ascending sort_order from -n to -1 (default items have 0 order)
      @order_first = argument.split(',').reverse.each.with_index.map{ |n, i| [n, -i-1] }.to_h
    when '--order-last'
      # give them ascending sort_order fron 1 to n (default items have 0 order)
      @order_last = argument.split(',').each.with_index.map{ |n, i| [n, i+1] }.to_h
    end
  end

  unless ARGV[0]
    puts <<~HELP
      Usage:
        --format f, -f f:
          Output format like dot, pdf, png, svg, ps, etc. Default is DOT.
        --output o, -o o:
          Output file name. STDOUT, if not given.
        --order-first
        --order-last
          Comma-separated list of queues/exchanges names that should be sorted first/last.
          Depending on the schema complexity, the ordering effect may be limited.
        {JSON_FILENAME}:
          Schema export file. REQUIRED.
    HELP
    exit(1)
  end
end

def create_graph(data)
  qs = data['queues'].map{ RmqQueue.from_json(_1) }
  qs.each do |q|
    q.sort_order = @order_first[q.name] || @order_last[q.name] || 0
  end

  xs = data['exchanges'].map{ RmqExchange.from_json(_1) }
  xs.each do |x|
    x.sort_order = @order_first[x.name] || @order_last[x.name] || 0
  end

  binds = data['bindings'].map do |b|
    src = xs.find { |x| x.vhost == b['vhost'] && x.name == b['source'] }
    dst_container = if b['destination_type'] == 'queue'
                      qs
                    elsif b['destination_type'] == 'exchange'
                      xs
                    end
    dst = dst_container&.find { |x| x.vhost == b['vhost'] && x.name == b['destination'] }
    unless src
      puts "#{b['source']} exchange not found"
      next
    end
    unless dst
      puts "#{b['destination']} #{b['destination_type']} not found"
      next
    end
    RmqBinding.new source: src,
                   vhost: b['vhost'],
                   destination: dst,
                   routing_key: b['routing_key'],
                   dsx: false,
                   arguments: b['arguments']
  end

  # Add DLX bindings
  qs.filter(&:dlx?).each do |q|
    dst = xs.find { |x| x.vhost == q.vhost && x.name == q.arguments['x-dead-letter-exchange'] }
    unless dst
      puts "#{b.destination} exchange not found"
      next
    end
    binds.push(RmqBinding.new(source: q,
                              vhost: q.vhost,
                              destination: dst,
                              routing_key: q.arguments['x-dead-letter-routing-key'] || '',
                              arguments: {},
                              dsx: true))
  end

  nodes = (xs + qs).sort
  vhosts = (qs.map(&:vhost) + xs.map(&:vhost) + binds.map(&:vhost)).to_set

  GraphViz::new(:G, type: :digraph) do |graph|
    vhosts.each do |vhost|
      g = graph.subgraph("cluster_#{vhost}", label: vhost)
      nodes.filter{ _1.vhost == vhost }.each { |node| NodeDecorator.new(node).add_to_graph(g) }
      binds.filter{ _1.vhost == vhost }.each { |bind| EdgeDecorator.new(bind).add_to_graph(g) }
    end
  end
end

##### main

read_arguments
data = JSON.load_file(ARGV[0])
g = create_graph(data)
puts g.save(@output_format => @output_file)
