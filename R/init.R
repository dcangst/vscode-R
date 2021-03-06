if (interactive() &&
  Sys.getenv("RSTUDIO") == "" &&
  Sys.getenv("TERM_PROGRAM") == "vscode") {
  if (requireNamespace("jsonlite", quietly = TRUE)) local({
    # cleanup previous version
    removeTaskCallback("vscode-R")
    options(vscodeR = NULL)

    .vsc.name <- "tools:vscode"
    if (.vsc.name %in% search()) {
      detach(.vsc.name, character.only = TRUE)
    }

    .vsc <- local({
      pid <- Sys.getpid()
      wd <- getwd()
      tempdir <- tempdir()
      homedir <- Sys.getenv(
        if (.Platform$OS.type == "windows") "USERPROFILE" else "HOME"
      )
      dir_extension <- file.path(homedir, ".vscode-R")
      request_file <- file.path(dir_extension, "request.log")
      request_lock_file <- file.path(dir_extension, "request.lock")

      options(help_type = "html")

      get_timestamp <- function() {
        format.default(Sys.time(), nsmall = 6)
      }

      unbox <- jsonlite::unbox

      request <- function(command, ...) {
        obj <- list(
          time = Sys.time(),
          pid = pid,
          wd = wd,
          command = command,
          ...
        )
        jsonlite::write_json(obj, request_file,
          auto_unbox = TRUE, null = "null", force = TRUE)
        cat(get_timestamp(), file = request_lock_file)
      }

      capture_str <- function(object) {
        utils::capture.output(
          utils::str(object, max.level = 0, give.attr = FALSE)
        )
      }

      rebind <- function(sym, value, ns) {
        if (is.character(ns)) {
          Recall(sym, value, getNamespace(ns))
          pkg <- paste0("package:", ns)
          if (pkg %in% search()) {
            Recall(sym, value, as.environment(pkg))
          }
        } else if (is.environment(ns)) {
          if (bindingIsLocked(sym, ns)) {
            unlockBinding(sym, ns)
            on.exit(lockBinding(sym, ns))
          }
          assign(sym, value, ns)
        } else {
          stop("ns must be a string or environment")
        }
      }

      dir_session <- file.path(tempdir, "vscode-R")
      dir.create(dir_session, showWarnings = FALSE, recursive = TRUE)

      removeTaskCallback("vsc.globalenv")
      show_globalenv <- isTRUE(getOption("vsc.globalenv", TRUE))
      if (show_globalenv) {
        globalenv_file <- file.path(dir_session, "globalenv.json")
        globalenv_lock_file <- file.path(dir_session, "globalenv.lock")
        file.create(globalenv_lock_file, showWarnings = FALSE)

        update_globalenv <- function(...) {
          tryCatch({
            objs <- eapply(.GlobalEnv, function(obj) {
              str <- capture_str(obj)[[1L]]
              info <- list(
                class = class(obj),
                type = unbox(typeof(obj)),
                length = unbox(length(obj)),
                str = unbox(trimws(str))
              )
              if ((is.list(obj) ||
                is.environment(obj)) &&
                !is.null(names(obj))) {
                info$names <- names(obj)
              }
              if (isS4(obj)) {
                info$slots <- slotNames(obj)
              }
              info
            }, all.names = FALSE, USE.NAMES = TRUE)
            jsonlite::write_json(objs, globalenv_file, pretty = FALSE)
            cat(get_timestamp(), file = globalenv_lock_file)
          }, error = message)
          TRUE
        }

        update_globalenv()
        addTaskCallback(update_globalenv, name = "vsc.globalenv")
      }

      removeTaskCallback("vsc.plot")
      show_plot <- !identical(getOption("vsc.plot", "Two"), FALSE)
      if (show_plot) {
        dir_plot_history <- file.path(dir_session, "images")
        dir.create(dir_plot_history, showWarnings = FALSE, recursive = TRUE)
        plot_file <- file.path(dir_session, "plot.png")
        plot_lock_file <- file.path(dir_session, "plot.lock")
        file.create(plot_file, plot_lock_file, showWarnings = FALSE)

        plot_history_file <- NULL
        plot_updated <- FALSE
        null_dev_id <- c(pdf = 2L)
        null_dev_size <- c(7 + pi, 7 + pi)

        check_null_dev <- function() {
          identical(dev.cur(), null_dev_id) &&
            identical(dev.size(), null_dev_size)
        }

        new_plot <- function() {
          if (check_null_dev()) {
            plot_history_file <<- file.path(dir_plot_history,
              format(Sys.time(), "%Y%m%d-%H%M%OS6.png"))
            plot_updated <<- TRUE
          }
        }

        options(
          device = function(...) {
            pdf(NULL,
              width = null_dev_size[[1L]],
              height = null_dev_size[[2L]],
              bg = "white")
            dev.control(displaylist = "enable")
          }
        )

        update_plot <- function(...) {
          tryCatch({
            if (plot_updated && check_null_dev()) {
              plot_updated <<- FALSE
              record <- recordPlot()
              if (length(record[[1L]])) {
                dev_args <- getOption("vsc.dev.args")
                do.call(png, c(list(filename = plot_file), dev_args))
                on.exit({
                  dev.off()
                  cat(get_timestamp(), file = plot_lock_file)
                  if (!is.null(plot_history_file)) {
                    file.copy(plot_file, plot_history_file, overwrite = TRUE)
                  }
                })
                replayPlot(record)
              }
            }
          }, error = message)
          TRUE
        }

        setHook("plot.new", new_plot, "replace")
        setHook("grid.newpage", new_plot, "replace")

        rebind(".External.graphics", function(...) {
          out <- .Primitive(".External.graphics")(...)
          if (check_null_dev()) {
            plot_updated <<- TRUE
          }
          out
        }, "base")

        update_plot()
        addTaskCallback(update_plot, name = "vsc.plot")
      }

      show_view <- !identical(getOption("vsc.view", "Two"), FALSE)
      if (show_view) {
        dataview_data_type <- function(x) {
          if (is.numeric(x)) {
            if (is.null(attr(x, "class"))) {
              "num"
            } else {
              "num-fmt"
            }
          } else if (inherits(x, "Date")) {
            "date"
          } else {
            "string"
          }
        }

        dataview_table <- function(data) {
          if (is.data.frame(data)) {
            nrow <- nrow(data)
            colnames <- colnames(data)
            if (is.null(colnames)) {
              colnames <- sprintf("(X%d)", seq_len(ncol(data)))
            } else {
              colnames <- trimws(colnames)
            }
            if (.row_names_info(data) > 0L) {
              rownames <- rownames(data)
              rownames(data) <- NULL
            } else {
              rownames <- seq_len(nrow)
            }
            data <- c(list(" " = rownames), .subset(data))
            colnames <- c(" ", colnames)
            types <- vapply(data, dataview_data_type,
              character(1L), USE.NAMES = FALSE)
            data <- vapply(data, function(x) {
              trimws(format(x))
            }, character(nrow), USE.NAMES = FALSE)
            dim(data) <- c(length(rownames), length(colnames))
          } else if (is.matrix(data)) {
            if (is.factor(data)) {
              data <- format(data)
            }
            types <- rep(dataview_data_type(data), ncol(data))
            colnames <- colnames(data)
            colnames(data) <- NULL
            if (is.null(colnames)) {
              colnames <- sprintf("(X%d)", seq_len(ncol(data)))
            } else {
              colnames <- trimws(colnames)
            }
            rownames <- rownames(data)
            rownames(data) <- NULL
            data <- trimws(format(data))
            if (is.null(rownames)) {
              types <- c("num", types)
              rownames <- seq_len(nrow(data))
            } else {
              types <- c("string", types)
              rownames <- trimws(rownames)
            }
            dim(data) <- c(length(rownames), length(colnames))
            colnames <- c(" ", colnames)
            data <- cbind(rownames, data)
          } else {
            stop("data must be data.frame or matrix")
          }
          columns <- .mapply(function(title, type) {
            class <- if (type == "string") "text-left" else "text-right"
            list(title = unbox(title),
              className = unbox(class),
              type = unbox(type))
          }, list(colnames, types), NULL)
          list(columns = columns, data = data)
        }

        dataview <- function(x, title, viewer = getOption("vsc.view", "Two")) {
          if (missing(title)) {
            sub <- substitute(x)
            title <- deparse(sub, nlines = 1)
          }
          if (is.environment(x)) {
            x <- eapply(x, function(obj) {
              data.frame(
                class = paste0(class(obj), collapse = ", "),
                type = typeof(obj),
                length = length(obj),
                size = as.integer(object.size(obj)),
                value = trimws(capture_str(obj)),
                stringsAsFactors = FALSE,
                check.names = FALSE
              )
            }, all.names = FALSE, USE.NAMES = TRUE)
            if (length(x)) {
              x <- do.call(rbind, x)
            } else {
              x <- data.frame(
                class = character(),
                type = character(),
                length = integer(),
                size = integer(),
                value = character(),
                stringsAsFactors = FALSE,
                check.names = FALSE
              )
            }
          }
          if (is.data.frame(x) || is.matrix(x)) {
            data <- dataview_table(x)
            file <- tempfile(tmpdir = tempdir, fileext = ".json")
            jsonlite::write_json(data, file, matrix = "rowmajor")
            request("dataview", source = "table", type = "json",
              title = title, file = file, viewer = viewer)
          } else if (is.list(x)) {
            tryCatch({
              file <- tempfile(tmpdir = tempdir, fileext = ".json")
              jsonlite::write_json(x, file, auto_unbox = TRUE)
              request("dataview", source = "list", type = "json",
                title = title, file = file, viewer = viewer)
            }, error = function(e) {
              file <- file.path(tempdir, paste0(make.names(title), ".txt"))
              text <- utils::capture.output(print(x))
              writeLines(text, file)
              request("dataview", source = "object", type = "txt",
                title = title, file = file, viewer = viewer)
            })
          } else {
            file <- file.path(tempdir, paste0(make.names(title), ".R"))
            if (is.primitive(x)) {
              code <- utils::capture.output(print(x))
            } else {
              code <- deparse(x)
            }
            writeLines(code, file)
            request("dataview", source = "object", type = "R",
              title = title, file = file, viewer = viewer)
          }
        }

        rebind("View", dataview, "utils")
      }

      attach <- function() {
        rstudioapi_util_env$update_addin_registry(addin_registry)
        request("attach",
          tempdir = tempdir,
          plot = getOption("vsc.plot", "Two"))
      }

      path_to_uri <- function(path) {
        if (length(path) == 0) {
          return(character())
        }
        path <- path.expand(path)
        if (.Platform$OS.type == "windows") {
          prefix <- "file:///"
          path <- gsub("\\", "/", path, fixed = TRUE)
        } else {
          prefix <- "file://"
        }
        paste0(prefix, utils::URLencode(path))
      }

      browser <- function(url, title = url, ...,
        viewer = getOption("vsc.browser", "Active")) {
        if (grepl("^https?\\://(127\\.0\\.0\\.1|localhost)(\\:\\d+)?", url)) {
          request("browser", url = url, title = title, ..., viewer = viewer)
        } else if (grepl("^https?\\://", url)) {
          message("VSCode WebView only supports showing local http content.")
          message("Opening in external browser...")
          request("browser", url = url, title = title, ..., viewer = FALSE)
        } else if (file.exists(url)) {
          url <- normalizePath(url, "/", mustWork = TRUE)
          if (grepl("\\.html?$", url, ignore.case = TRUE)) {
            message("VSCode WebView has restricted access to local file.")
            message("Opening in external browser...")
            request("browser", url = path_to_uri(url),
              title = title, ..., viewer = FALSE)
          } else {
            request("dataview", source = "object", type = "txt",
              title = title, file = url, viewer = viewer)
          }
        } else {
          stop("File not exists")
        }
      }

      webview <- function(url, title, ..., viewer) {
        if (!is.character(url)) {
          real_url <- NULL
          temp_viewer <- function(url, ...) {
            real_url <<- url
          }
          op <- options(viewer = temp_viewer, page_viewer = temp_viewer)
          on.exit(options(op))
          print(url)
          if (is.character(real_url)) {
            url <- real_url
          } else {
            stop("Invalid object")
          }
        }
        if (grepl("^https?\\://(127\\.0\\.0\\.1|localhost)(\\:\\d+)?", url)) {
          request("browser", url = url, title = title, ..., viewer = viewer)
        } else if (grepl("^https?\\://", url)) {
          message("VSCode WebView only supports showing local http content.")
          message("Opening in external browser...")
          request("browser", url = url, title = title, ..., viewer = FALSE)
        } else if (file.exists(url)) {
          file <- normalizePath(url, "/", mustWork = TRUE)
          request("webview", file = file, title = title, viewer = viewer, ...)
        } else {
          stop("File not exists")
        }
      }

      viewer <- function(url, title = NULL, ...,
        viewer = getOption("vsc.viewer", "Two")) {
        if (is.null(title)) {
          expr <- substitute(url)
          if (is.character(url)) {
            title <- "Viewer"
          } else {
            title <- deparse(expr, nlines = 1)
          }
        }
        webview(url = url, title = title, ..., viewer = viewer)
      }

      page_viewer <- function(url, title = NULL, ...,
        viewer = getOption("vsc.page_viewer", "Active")) {
        if (is.null(title)) {
          expr <- substitute(url)
          if (is.character(url)) {
            title <- "Page Viewer"
          } else {
            title <- deparse(expr, nlines = 1)
          }
        }
        webview(url = url, title = title, ..., viewer = viewer)
      }

      options(
        browser = browser,
        viewer = viewer,
        page_viewer = page_viewer
      )

      # rstudioapi
      response_timeout <- 5
      response_lock_file <- file.path(dir_session, "response.lock")
      response_file <- file.path(dir_session, "response.log")
      file.create(response_lock_file, showWarnings = FALSE)
      file.create(response_file, showWarnings = FALSE)
      addin_registry <- file.path(dir_session, "addins.json")
      # This is created in attach()

      get_response_timestamp <- function() {
          readLines(response_lock_file)
      }
      # initialise the reponse timestamp to empty string
      response_time_stamp <- ""

      get_response_lock <- function() {
        lock_time_stamp <- get_response_timestamp()
        if (isTRUE(lock_time_stamp != response_time_stamp)) {
          response_time_stamp <<- lock_time_stamp
          TRUE
        } else FALSE
      }

      request_response <- function(command, ...) {
        request(command, ..., sd = dir_session)
        wait_start <- Sys.time()
        while (!get_response_lock()) {
          if ((Sys.time() - wait_start) > response_timeout)
            stop("Did not receive a response from VSCode-R API within ",
                  response_timeout, " seconds.")
          Sys.sleep(0.1)
        }
        jsonlite::read_json(response_file)
      }

     rstudioapi_util_env <- new.env()
     rstudioapi_env <- new.env(parent = rstudioapi_util_env)
     source(file.path(dir_extension, "rstudioapi_util.R"),
       local = rstudioapi_util_env,
     )
     source(file.path(dir_extension, "rstudioapi.R"),
       local = rstudioapi_env
     )
     setHook(
       packageEvent("rstudioapi", "onLoad"),
       function(...) rstudioapi_util_env$rstudioapi_patch_hook(rstudioapi_env)
     )


      environment()
    })

    .vsc.attach <- .vsc$attach
    .vsc.view <- .vsc$dataview
    .vsc.browser <- .vsc$browser
    .vsc.viewer <- .vsc$viewer
    .vsc.page_viewer <- .vsc$page_viewer

    attach(environment(), name = .vsc.name)

    .vsc.attach()
  }) else {
    message("VSCode R Session Watcher requires jsonlite.")
    message("Please install it with install.packages(\"jsonlite\").")
  }
}
