# frozen_string_literal: true
#
# Runs on a schedule via GitHub Actions.
# Loads existing data/powerball_data.json, drops current year records,
# fetches only the current year from Texas Lottery, merges and writes.
#
# On first run (no JSON file yet), falls back to a full historical fetch.

require 'net/http'
require 'json'
require 'date'
require 'fileutils'
require 'strscan'

OUTPUT_PATH = File.expand_path('../../data/powerball_data.json', __FILE__)
CUTOFF_DATE = Date.new(2015, 10, 7)
BASE_URL    = 'https://www.texaslottery.com'

TOTAL_WHITE_BALLS = 69
TOTAL_POWERBALLS  = 26
WHITE_BALL_COUNT  = 5

YEAR_URLS = {
  2026 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_345119599.html',
  2025 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_160439026.html',
  2024 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_665997651.html',
  2023 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_1171556276.html',
  2022 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_1677114901.html',
  2021 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_2112293770.html',
  2020 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_1606735145.html',
  2019 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_925620013.html',
  2018 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_1431178638.html',
  2017 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_1936737263.html',
  2016 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_1852671408.html',
  2015 => '/export/sites/lottery/Games/Powerball/Winning_Numbers/index.html_1347112783.html'
}.freeze

module Combinatorics
  def self.choose(n, k)
    return 0 if k > n
    return 1 if k == 0 || k == n

    k = n - k if k > n - k
    (0...k).reduce(1) { |result, i| result * (n - i) / (i + 1) }
  end

  def self.white_ball_rank(sorted_balls)
    rank = 0
    start = 1
    sorted_balls.each_with_index do |ball, i|
      (start...ball).each do |v|
        rank += choose(TOTAL_WHITE_BALLS - v, WHITE_BALL_COUNT - 1 - i)
      end
      start = ball + 1
    end
    rank
  end
end

class PowerballRecord
  attr_reader :date, :winning_combo_index, :has_winner

  def initialize(date:, winning_combo_index:, has_winner:)
    @date = date
    @winning_combo_index = winning_combo_index
    @has_winner = has_winner
  end

  def to_h
    {
      date: date.to_s,
      winningComboIndex: winning_combo_index,
      hasWinner: has_winner
    }
  end
end

class TexasLotteryFetcher
  HEADERS = {
    'User-Agent' => 'Mozilla/5.0 (compatible; powerball-sync/1.0)',
    'Accept'     => 'text/html'
  }.freeze

  def fetch_year(year)
    path = YEAR_URLS[year]
    raise "No URL configured for year #{year}" unless path

    uri  = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
    http.ca_file      = ca_file

    response = http.get(uri.path, HEADERS)
    raise "Failed to fetch #{year}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  private

  def ca_file
    # macOS
    return '/etc/ssl/cert.pem' if File.exist?('/etc/ssl/cert.pem')
    # Linux (GitHub Actions / Ubuntu)
    return '/etc/ssl/certs/ca-certificates.crt' if File.exist?('/etc/ssl/certs/ca-certificates.crt')

    nil
  end
end

class HtmlTableParser
  def parse(html)
    rows = []
    current_row = nil
    current_cell = nil
    in_table = false
    table_done = false

    scanner = StringScanner.new(html)

    until scanner.eos? || table_done
      if scanner.scan(/<table[^>]*>/i)
        in_table = true
      elsif scanner.scan(%r{</table>}i)
        table_done = true
      elsif in_table && scanner.scan(/<tr[^>]*>/i)
        current_row = []
      elsif in_table && scanner.scan(%r{</tr>}i)
        rows << current_row if current_row&.any?
        current_row = nil
      elsif in_table && scanner.scan(/<t[dh][^>]*>/i)
        current_cell = +''
      elsif in_table && scanner.scan(%r{</t[dh]>}i)
        if current_row && current_cell
          current_row << current_cell.gsub(/\s+/, ' ').strip
          current_cell = nil
        end
      elsif current_cell
        text = scanner.scan(/[^<]+/)
        current_cell << text if text
        scanner.scan(/<[^>]+>/) unless text
      else
        scanner.scan(/[^<]+|</)
      end
    end

    rows
  end
end

class DrawParser
  def parse(rows)
    rows.select { |r| r.length >= 6 && looks_like_date?(r[0]) }
        .filter_map { |row| parse_row(row) }
  end

  private

  def looks_like_date?(str)
    str.match?(/\A\d{2}\/\d{2}\/\d{4}\z/)
  end

  def parse_row(row)
    date_str, numbers_str, powerball_str, _, _, jackpot_winners_str = row

    date = parse_date(date_str) or return nil
    return nil if date < CUTOFF_DATE

    white_balls = parse_white_balls(numbers_str) or return nil
    powerball   = powerball_str.to_i
    return nil if powerball < 1 || powerball > TOTAL_POWERBALLS

    PowerballRecord.new(
      date: date,
      winning_combo_index: compute_index(white_balls, powerball),
      has_winner: parse_winner(jackpot_winners_str)
    )
  end

  def parse_date(str)
    Date.strptime(str, '%m/%d/%Y')
  rescue Date::Error
    nil
  end

  def parse_white_balls(str)
    return nil unless str

    balls = str.scan(/\d+/).map(&:to_i)
    return nil if balls.length != 5
    return nil if balls.any? { |b| b < 1 || b > TOTAL_WHITE_BALLS }

    balls.sort
  end

  def parse_winner(str)
    return false if str.nil? || str.strip.empty? || str.strip.downcase == 'roll'
    true
  end

  def compute_index(white_balls, powerball)
    Combinatorics.white_ball_rank(white_balls) * TOTAL_POWERBALLS + (powerball - 1)
  end
end

class DataStore
  def load
    return [] unless File.exist?(OUTPUT_PATH)

    JSON.parse(File.read(OUTPUT_PATH), symbolize_names: true)
  rescue JSON::ParserError
    []
  end

  def write(records)
    FileUtils.mkdir_p(File.dirname(OUTPUT_PATH))
    File.write(OUTPUT_PATH, JSON.pretty_generate(records.map(&:to_h)))
    puts "Wrote #{records.length} records to #{OUTPUT_PATH}"
  end
end

class PowerballSync
  def initialize(
    fetcher:      TexasLotteryFetcher.new,
    table_parser: HtmlTableParser.new,
    draw_parser:  DrawParser.new,
    store:        DataStore.new
  )
    @fetcher      = fetcher
    @table_parser = table_parser
    @draw_parser  = draw_parser
    @store        = store
  end

  def run
    current_year = Date.today.year
    existing     = @store.load

    if existing.empty?
      puts "No existing data found — performing full historical fetch"
      years_to_fetch = YEAR_URLS.keys.sort
    else
      puts "Loaded #{existing.length} existing records"
      puts "Refreshing #{current_year} data only"
      years_to_fetch = [current_year]
    end

    # Drop records for the years we're about to re-fetch
    retained = existing.reject do |r|
      Date.parse(r[:date]).year == current_year
    end

    new_records = fetch_years(years_to_fetch)

    all_records = (retained.map { |r| to_record(r) } + new_records)
                    .sort_by(&:date)

    winners = all_records.count(&:has_winner)
    puts "Total: #{all_records.length} draws, #{winners} jackpot winners"

    @store.write(all_records)
  end

  private

  def fetch_years(years)
    years.flat_map do |year|
      print "Fetching #{year}... "
      html  = @fetcher.fetch_year(year)
      recs  = @draw_parser.parse(@table_parser.parse(html))
      puts "#{recs.length} draws"
      sleep 0.5
      recs
    end
  end

  def to_record(hash)
    PowerballRecord.new(
      date: Date.parse(hash[:date]),
      winning_combo_index: hash[:winningComboIndex],
      has_winner: hash[:hasWinner]
    )
  end
end

PowerballSync.new.run if __FILE__ == $PROGRAM_NAME