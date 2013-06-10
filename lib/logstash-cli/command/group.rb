require 'time'
require 'yajl/json_gem'

module Group

  def self.indexes_from_interval(from, to)
    ret = []
    while from <= to
      ret << from.strftime("%F").gsub('-', '.')
      from += 86400
    end
    ret
  end

  # Very naive time range description parsing.
  def self.parse_time_range(desc)
    /(\d+)\s*(\w*)/ =~ desc
    value, units = $1, $2
    value = value.to_i
    start = case units.to_s.downcase
              when 'm', 'min', 'mins', 'minute', 'minutes'
                Time.now - value*60
              when 'h', 'hr', 'hrs', 'hour', 'hours'
                Time.now - value*3600
              when 'd', 'day', 'days'
                Time.now - value*86400
              when 'w', 'wk', 'wks', 'week', 'weeks'
                Time.now - 7.0*value*86400
              when 'y', 'yr', 'yrs', 'year', 'years'
                Time.now - 365.0*value*86400
              else
                raise ArgumentError
            end
    [start, Time.now]
  end

  def _group(pattern,options)
    es_url = options[:esurl]
    countfield =  options[:countfield].to_sym
    index_prefix =  options[:index_prefix]
    metafields = options[:meta].split(',')
    fields = options[:fields].split(',')

    begin
      from_time, to_time = if options[:from] && options[:to]
                             [ Time.parse(options[:from]),
                               Time.parse(options[:to]) ]
                           elsif options[:from] && ! options[:to]
                             [Time.parse(options[:from]), Time.now]
                           elsif options[:last]
                             Group.parse_time_range(options[:last])
                           end
    rescue ArgumentError
      $stderr.puts "Something went wrong while parsing the date range."
      exit -1
    end

    index_range = Group.indexes_from_interval(from_time, to_time).map do |i|
      "#{index_prefix}#{i}"
    end

    $stderr.puts "Searching #{es_url}[#{index_range.first}..#{index_range.last}] - #{pattern}"

    # Reformat time interval to match logstash's internal timestamp'
    from = from_time.strftime('%FT%T')
    to = to_time.strftime('%FT%T')

    # Total of results to show
    total_result_size = options[:size]

    # For this index the number of results to show
    # Previous indexes might already have generate results

    running_result_size = total_result_size.to_i

    items = {}

    # We reverse the order of working ourselves through the index
    index_range.reverse.each do |idx|
      begin
        Tire.configure {url es_url}
        search = Tire.search(idx) do
          query do
            string "#{pattern}"
          end
          sort do
            by :@timestamp, 'desc'
          end
          filter "range", "@timestamp" => { "from" => from, "to" => to}
          size running_result_size
        end
      rescue Exception => e
        $stderr.puts e
        $stderr.puts "\nSomething went wrong with the search. This is usually due to lucene query parsing of the 'grep' option"
        exit
      end
      # puts "#{search.to_json}"

      begin
        result = Array.new

        # Decrease the number of results to get from the next index
        running_result_size -= search.results.size

        search.results.each do |res|
          key = res[:@fields][countfield]
          if key then
            key = key.to_sym
            if !items[key] then 
              items[key] = []
            end
            items[key] = items[key] + [res]
          end
        end
      rescue ::Tire::Search::SearchRequestFailed => e
        # If we got a 404 it likely means we simply don't have logs for that day, not failing over necessarily.
        $stderr.puts e.message unless search.response.code == 404
      end
    end
    items = items.sort_by  {|_key, value| -value.length}
    items.each do |item|
      key = item[0]
      val = item[1]
      puts "#{key}|#{val.length}|#{val.last[:@fields][:level]}|#{val.last[:@message]}"
    end
  end
end
