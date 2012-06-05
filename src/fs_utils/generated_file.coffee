fs = require 'fs'
inflection = require 'inflection'
sysPath = require 'path'
async = require 'async'
common = require './common'
helpers = require '../helpers'
logger = require '../logger'

# Load and cache static files, used for require_definition.js and test_require_definition.js
_getStaticFile = async.memoize (filename, callback) ->
  path = sysPath.join __dirname, '..', '..', 'vendor', filename
  fs.readFile path, (error, result) ->
    return logger.error error if error?
    callback null, result.toString()

# The definition would be added on top of every filewriter .js file.
getRequireDefinition     = _getStaticFile.bind null, 'require_definition.js'
getTestRequireDefinition = _getStaticFile.bind null, 'test_require_definition.js'


# File which is generated by brunch from other files.
module.exports = class GeneratedFile
  # 
  # path        - path to file that will be generated.
  # sourceFiles - array of `fs_utils.SourceFile`-s.
  # config      - parsed application config.
  # 
  constructor: (@path, @sourceFiles, @config, minifiers) ->    
    @type = if @sourceFiles.some((file) -> file.type is 'javascript')
      'javascript'
    else
      'stylesheet'
    @minifier = minifiers.filter((minifier) => minifier.type is @type)[0]
    @isTestsFile = @type is 'javascript' and /tests\.js$/.test @path
    Object.freeze(this)

  _extractOrder: (files, config) ->
    types = files.map (file) -> inflection.pluralize file.type
    Object.keys(config.files)
      .filter (key) ->
        key in types
      # Extract order value from config.
      .map (key) ->
        config.files[key].order
      # Join orders together.
      .reduce (memo, array) ->
        array or= {}
        {
          before: memo.before.concat(array.before or []),
          after: memo.after.concat(array.after or []),
          vendorPaths: [config.paths.vendor]
        }
      , {before: [], after: []}

  _sort: (files) ->
    paths = files.map (file) -> file.path
    indexes = {}
    files.forEach (file, index) -> indexes[file.path] = file
    order = @_extractOrder files, @config
    helpers.sortByConfig(paths, order).map (path) ->
      indexes[path]

  _loadTestFiles: (files) ->
    files
      .map (file) ->
        file.path
      .filter (path) ->
        /_test\.[a-z]+$/.test path
      .map (path) ->
        path = path.replace /\\/g, '/'
        path.substring 0, path.lastIndexOf '.'
      .map (path) ->
        "this.require('#{path}');"
      .join '\n'

  # Private: Collect content from a list of files and wrap it with
  # require.js module definition if needed.
  # Returns string.
  _join: (files, callback) ->
    logger.debug "Joining files '#{files.map((file) -> file.path).join(', ')}'
 to '#{@path}'"
    joined = files.map((file) -> file.cache.data).join('')
    if @type is 'javascript'
      if @isTestsFile
        getTestRequireDefinition (error, requireDefinition) =>
          callback error, requireDefinition + joined + '\n' + @_loadTestFiles(files)
      else
        getRequireDefinition (error, requireDefinition) =>
          callback error, requireDefinition + joined
    else
      process.nextTick =>
        callback null, joined

  # Private: minify data.
  # 
  # data     - string of js / css that will be minified.
  # callback - function that would be executed with (minifyError, data).
  # 
  # Returns nothing.
  _minify: (data, callback) ->
    if @config.minify and @minifier?.minify?
      @minifier.minify data, @path, callback
    else
      callback null, data

  # Joins data from source files, minifies it and writes result to 
  # path of current generated file.
  # 
  # callback - minify / write error or data of written file.
  # 
  # Returns nothing.
  write: (callback) ->
    @_join (@_sort @sourceFiles), (error, joined) =>
      return callback error if error?
      @_minify joined, (error, data) =>
        return callback error if error?
        common.writeFile @path, data, callback
