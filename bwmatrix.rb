#!/usr/bin/ruby

require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE
require 'cute'
require 'pp'
require 'peach'
require 'net/ssh'
require 'optparse'
require 'erb'
require 'time'

# FIXME
#RestClient.log = 'stdout'

SSH_USER = 'lnussbaum'

TARGETS = {
  'nancy' => { :site => 'nancy', :resources => '{cluster<>\'graphite\'}/nodes=1' },
  'nancy.10g' => { :site => 'nancy', :resources => '{cluster=\'graphite\'}/nodes=1' },
  'reims' => { :site => 'reims', :resources => 'nodes=1' },
  'lille' => { :site => 'lille', :resources => 'nodes=1' },
  'luxembourg' => { :site => 'luxembourg', :resources => '{cluster=\'granduc\'}/nodes=1' },
  'luxembourg.10g' => { :site => 'luxembourg', :resources => '{cluster=\'petitprince\'}/nodes=1' },
  'lyon' => { :site => 'lyon', :resources => '{cluster=\'sagittaire\'}/nodes=1' },
  'lyon.10g' => { :site => 'lyon', :resources => '{cluster<>\'sagittaire\'}/nodes=1' },
  'grenoble' => { :site => 'grenoble', :resources => 'nodes=1' },
  'sophia' => { :site => 'sophia', :resources => 'nodes=1' },
  'nancy.talc' => { :site => 'nancy', :resources => '{cluster=\'talc\'}/nodes=1', :queue => 'production' },
  'nantes' => { :site => 'nantes', :resources => 'nodes=1' },
  'rennes' => { :site => 'rennes', :resources => '{cluster in (\'parapluie\',\'parapide\')}/nodes=1' },
  'rennes.10g' => { :site => 'rennes', :resources => '{cluster not in (\'parapluie\',\'parapide\')}/nodes=1' },
}

def do_measure(targets_restrict)
  $g5k = Cute::G5K::API.new

  targets = TARGETS
  if not targets_restrict.nil?
    targets.delete_if { |k, v| not targets_restrict.include?(k) }
  end

  # do all reservations
  targets.keys.peach do |name|
    t = targets[name]
    begin
      # FIXME
      t[:job] = $g5k.reserve(:site => t[:site], :resources => t[:resources], :walltime => '01:00:00', :wait => false, :queue => t[:queue])
    rescue Cute::G5K::RequestFailed, Cute::G5K::BadRequest
      puts "Error on #{name}, skipping"
      t[:job] = nil
      t[:state] = 'error'
    end
  end

  # wait to let OAR schedule jobs
  sleep 30

  # Get status
  targets.keys.peach do |name|
    t = targets[name]
    next if t[:job].nil?
    t[:job] = $g5k.get_job(t[:site], t[:job]['uid'])
  end

  targets.keys.each do |name|
    t = targets[name]
    next if t[:job].nil?
    t[:state] = t[:job]['state']
    if t[:job]['state'] != 'running'
      puts "Removing #{name} (job: #{t[:job]['uid']}, scheduled_at #{Time.at(t[:job]['scheduled_at'] || 0).to_s})"
      $g5k.release(t[:job])
    end
  end

  def find_pairs(targets)
    t1 = targets.select { |t| t =~ /\.10g$/ }
    targets_output = t1.product(t1)
    t2 = targets.select { |t| t !~ /\.10g$/ }
    targets_output += t2.product(t2)
    targets_output.reject! { |e| e[0] == e[1] }
    return targets_output
  end

  valid_targets = targets.select { |name, t| t[:state] == 'running' }.map { |e| e.first }
  pairs = find_pairs(valid_targets)
  valid_targets.peach do |t|
    t = targets[t]
    t[:node] = t[:job]['assigned_nodes'].first
    t[:ssh] = Net::SSH.start(t[:node], SSH_USER)
    t[:ssh].exec!('nuttcp -S')
  end

  def parse_output(o)
    o = o.split(/\n/)
    line1 = o[1]
    line1 = Hash[line1.split(' ').map { |e| e.split('=') }]
    linelast = o.last
    linelast = Hash[linelast.split(' ').map { |e| e.split('=') }]
    return { :avg_bw => linelast['rate_Mbps'], :bw_10s => line1['rate_Mbps'], :rtt => linelast['rtt_ms'] }
  end

  results = []
  pairs.each do |pair|
    from_name, to_name = pair ; from = targets[from_name] ; to = targets[to_name]
    puts "#{from_name} -> #{to_name}"
    t = Time::now
    sfb = from[:ssh].exec!("ip -s l")
    stb = to[:ssh].exec!("ip -s l")
    o = from[:ssh].exec!("nuttcp -fparse -i10 -T21 #{to[:node]}")
    sfa = from[:ssh].exec!("ip -s l")
    sta = to[:ssh].exec!("ip -s l")
    results << { :time => t, :from => from_name, :to => to_name, :output => o, :stats_from_before => sfb, :stats_to_before => stb, :stats_from_after => sfa, :stats_to_after => sta }.merge(parse_output(o))
  end

  fd = File::new("res/bw-matrix.log.#{Time::now.to_s.gsub(' ', '_')}", 'w')
  o = {}
  o[:targets] = targets
  o[:results] = results
  fd.puts JSON.pretty_generate(o)
  fd.close

  valid_targets.each do |t|
    t = targets[t]
    $g5k.release(t[:job])
  end
end

def parse_ipsl(str)
  ifaces = {}
  str.split(/^\d+: /).select { |l| l =~ /UP/ }.each do |para|
    ifname = para.split(': ', 2)[0]
    rx = para.split(/\n\s*/)[3].split(/\s+/).map { |e| e.to_i }
    tx = para.split(/\n\s*/)[5].split(/\s+/).map { |e| e.to_i }
    ifaces[ifname] = { :rx => rx, :tx => tx }
  end
  return ifaces
end

def analyze_stats(r)
  return if not r['stats_from_before']
  fb = parse_ipsl(r['stats_from_before'])
  fa = parse_ipsl(r['stats_from_after'])
  tb = parse_ipsl(r['stats_to_before'])
  ta = parse_ipsl(r['stats_to_after'])
  fb.each_pair do |k,ifs|
    ifs.each_pair do |iface, v|
      if v[2] != fa[k][iface][2]
        puts "Errors in source: #{r['time']} #{r['from']} -> #{r['to']}"
      end
    end
  end
  tb.each_pair do |k,ifs|
    ifs.each_pair do |iface, v|
      if v[2] != ta[k][iface][2]
        puts "Errors in dest: #{r['time']} #{r['from']} -> #{r['to']}"
      end
    end
  end
end

def do_render
  d = {}

  Dir::glob('/home/lnussbaum/bw-matrix/res/bw-matrix.log.*').each do |f|
    d[f] = JSON::parse(IO::read(f))
    d[f]['results'].each do |r|
      r['time'] = Time::parse(r['time'])
      r['avg_bw'] = r['avg_bw'].to_f
      r['bw_10s'] = r['bw_10s'].to_f
      r['rtt'] = r['rtt'].to_f
      analyze_stats(r)
    end
  end

  allres = []

  d.each_pair do |file, data|
    allres += data['results'] 
  end

  bestres = []
  allres.each do |r|
    lr1 = bestres.select { |e| e['from'] == r['from'] and e['to'] == r['to'] }.first
    if lr1.nil?
      bestres << r
    elsif lr1['bw_10s'] < r['bw_10s']
      bestres.delete(lr1)
      bestres << r
    end
  end

  latestres = []
  allres.each do |r|
    lr1 = latestres.select { |e| e['from'] == r['from'] and e['to'] == r['to'] }.first
    if lr1.nil?
      latestres << r
    elsif lr1['time'] < r['time']
      latestres.delete(lr1)
      latestres << r
    end
  end

  bestresg = bestres.group_by { |e| [e['from'], e['to']] }
  latestres.each do |l|
    l['avg_bw_p'] = (l['avg_bw'] / bestresg[[l['from'], l['to']]].first['avg_bw'] * 100).to_i
    l['bw_10s_p'] = (l['bw_10s'] / bestresg[[l['from'], l['to']]].first['bw_10s'] * 100).to_i
  end

  o = { :all => allres, :best => bestres, :latest => latestres }
  fd = File::new('/home/lnussbaum/public/bw.html', 'w')
  fd.puts ERB::new(IO::read('bw.erb')).result(binding)
  fd.close
end

options = {}
options[:render] = false
options[:measure] = false
options[:targets] = nil
OptionParser.new do |opts|

  opts.on("-t", "--targets TARGETS",  "Restrict to specific targets") do |v|
    options[:targets] = v.split(',')
  end

  opts.on("-m", "--measure",  "Do measurements") do |v|
    options[:measure] = true
  end

  opts.on("-r", "--render",  "Do rendering") do |v|
    options[:render] = true
  end
end.parse!

if options[:measure]
  do_measure(options[:targets])
end

if options[:render]
  do_render
end

