#!/usr/bin/env ruby

require "fileutils"
require "zlib"
require "uri"

CONFIG_FILE         = ARGV[0]
BASE_DIR            = File.dirname(File.expand_path(__FILE__))
MIRROR_DIR          = "/var/www/ubuntu_latest"
WORK_DIR            = "#{BASE_DIR}/work"
BANDWIDTH_LIMIT_KBS = 10000

# wget http://ftp.jaist.ac.jp/pub/Linux/ubuntu/dists/maverick/main/binary-amd64/Packages.gz
# rsync -avr -H  -n rsync://ftp.jaist.ac.jp/pub/Linux/ubuntu/ --files-from include_list . | tee rsynclog

def config()
  @conf ||= read_config CONFIG_FILE
end

def read_config(file)
  conf = []
  File.open(file).readlines.each do |line|
    next if line =~ /(^\s*$)|(^\s*#)/
    conf << line.chomp.split(/\s+/,4)
  end
  conf
end

# http://www.ibiblio.org/gferg/ldp/giles/repository/repository-2.html
def config_for(arg)
  config.select { |c| c[0] == arg }
end

def mirror_list
  h = Hash.new { |h,k| h[k] = [] }
  config_for("deb").each do |c|
    _, url, dist, groups = c
    %w(Release Release.gpg).map do |file|
      h[url] << "/dists/#{dist}/#{file}"
    end
    groups.split.each do |group|
      %w(Release Packages.gz Packages.bz2).map do |file|
        h[url] << "/dists/#{dist}/#{group}/binary-amd64/#{file}"
      end
    end
  end
  h
end

def init
  [BASE_DIR,MIRROR_DIR,WORK_DIR].each do |dir|
    FileUtils.mkdir_p dir unless File.directory? dir
  end
end

def sync_packages
  mirror_list.each do |url, files|
    host = URI.parse(url).host
    work_dir     = "#{WORK_DIR}/#{host}"
    index_list   = "#{work_dir}/indexes"
    package_list = "#{work_dir}/packages"
    mirror_dir   = "#{MIRROR_DIR}/#{host}"
    FileUtils.mkdir_p(work_dir) unless File.directory?(work_dir)

    # INDEX:
    #------------------------------------------------------------------
    File.open(index_list, 'w') {|f| f.puts files }
    system "rsync --no-motd -avH --bwlimit=#{BANDWIDTH_LIMIT_KBS} --files-from #{index_list} #{url} #{work_dir}"

    gzfiles = files.grep(/Packages.gz$/).map {|gz| File.join(work_dir, gz) }
    pkgs = gzfiles.inject([]) do |acc, gzfile|
      acc + Zlib::GzipReader.open( gzfile ).read.scan(/^Filename: (.*?)$/) )
    end
    File.open(package_list, 'w') {|f| f.puts pkgs.map{|e| "/#{e}"} }

    # PACKAGES:
    #------------------------------------------------------------------
    system "rsync --no-motd -avH --bwlimit=#{BANDWIDTH_LIMIT_KBS} --files-from #{package_list} #{url} #{mirror_dir}"

    cleanup(work_dir, index_list)
    cleanup(mirror_dir, package_list, index_list )
    FileUtils.rm_rf("#{mirror_dir}/dists", :verbose => true)
    system("cp -al #{work_dir}/dists #{mirror_dir}")
  end
end

# sync_packages
def cleanup(dir, *file_list)
  puts "# Cleaning files in `#{dir}' .. not listed in #{file_list.join(" or ")}"
  puts
  should_exist = file_list.inject([]) do |acc, file|
    acc + open(file).readlines.map {|e| File.join(dir, e.chomp) }
  end
  actual = Dir.glob("#{dir}/**/*")
  should_delete = (actual - should_exist).select { |e| FileTest.file? e }
  unless should_delete.empty?
    FileUtils.rm_f(should_delete, :verbose => true, :noop => true)
    # FileUtils.rm_f(should_delete, :verbose => true)
  end
end

def main
  init
  sync_packages
end
main
