#!/usr/bin/env ruby
require "fileutils"
require "zlib"
require "uri"

CONFIG_FILE         = ARGV[0]
BASE_DIR            = File.dirname(File.expand_path(__FILE__))
MIRROR_DIR          = "#{BASE_DIR}/mirror"
WORK_DIR            = "#{BASE_DIR}/work"
BANDWIDTH_LIMIT_KBS = 7000 # kilobytes per second.
ARCH = %w(amd64)
# ARCH = %w(amd64 i386)

Signal.trap(:INT) { puts "Interrupted"; exit 1 }

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
        ARCH.each do |arch|
          h[url] << "/dists/#{dist}/#{group}/binary-#{arch}/#{file}"
        end
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
    host         = URI.parse(url).host
    scheme       = URI.parse(url).scheme
    path         = URI.parse(url).path
    work_dir     = "#{WORK_DIR}/#{host}"
    index_list   = "#{work_dir}/indexes"
    package_list = "#{work_dir}/packages"
    work_root    = "#{work_dir}#{path}"
    mirror_root  = "#{MIRROR_DIR}/#{host}#{path}"

    # INDEX:
    #------------------------------------------------------------------
    FileUtils.mkdir_p work_dir
    File.open(index_list, 'w') {|f| f.puts files }

    if scheme == 'rsync'
      FileUtils.mkdir_p "#{work_root}"
      cmd = "rsync -avH --safe-links --bwlimit=#{BANDWIDTH_LIMIT_KBS} --files-from #{index_list} #{url} #{work_root}"
      system(cmd)
    elsif scheme == 'http'
      Dir.chdir(WORK_DIR) do
        cmd = "cat #{index_list} | sed -e 's/^/\./' | wget -B #{url}/ --limit-rate=#{BANDWIDTH_LIMIT_KBS*1000} -t 0 -r -N -l inf -i -"
        system(cmd)
      end
    end

    # PACKAGES:
    #------------------------------------------------------------------
    gzfiles =  Dir.glob("#{work_root}/**/Packages.gz")
    pkgs = gzfiles.inject([]) do |acc, gzfile|
      acc + Zlib::GzipReader.open( gzfile ).read.scan(/^Filename: (.*?)$/)
    end
    File.open(package_list, 'w') {|f| f.puts pkgs.map{|e| "/#{e}"} }

    if scheme == 'rsync'
      FileUtils.mkdir_p "#{mirror_root}"
      system "rsync -avH -L --safe-links --bwlimit=#{BANDWIDTH_LIMIT_KBS} --files-from #{package_list} #{url} #{mirror_root}"
    elsif scheme == 'http'
      Dir.chdir(MIRROR_DIR) do
        cmd = "cat #{package_list} | sed -e 's/^/\./' | wget -B #{url}/ --limit-rate=#{BANDWIDTH_LIMIT_KBS} -t 0 -r -N -l inf -i -"
        system(cmd)
      end
    end

    # Cleanup:
    #------------------------------------------------------------------
    FileUtils.rm_rf("#{mirror_root}/dists", :verbose => true)
    system("cp -al #{work_root}/dists #{mirror_root}/dists")
    should_exist = [package_list, index_list].inject([]) do |acc, list|
      acc + File.open(list).readlines.map{|e| e.chomp.sub(/^\//,'') }
    end
    cleanup("#{mirror_root}", should_exist)
  end
end

# sync_packages
def cleanup(dir, should_exist)
  puts
  puts "## Cleaning files in `#{dir}'"
  puts
  Dir.chdir(dir) do
    actual = Dir.glob("**/*")
    should_delete = (actual - should_exist).select { |e| FileTest.file? e }

    unless should_delete.empty?
      # FileUtils.rm_f(should_delete, :verbose => true, :noop => true)
      FileUtils.rm_f(should_delete, :verbose => true)
    end
  end
end

def main
  init
  sync_packages
end
main
