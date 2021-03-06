eventstudy <- function(firm.returns,
                       event.list,
                       event.window = 10,
                       is.levels =  FALSE,
                       type = "marketModel",
                       to.remap = TRUE,
                       remap = "cumsum",
                       inference = TRUE,
                       inference.strategy = "bootstrap",
                       model.args = NULL) {
  stopifnot(event.window > 0)
  
  if (type == "None" && !is.null(firm.returns)) {
    outputModel <- firm.returns
    if (length(model.args) != 0) {
      warning(deparse("type"), " = ", deparse("None"),
              " does not take extra arguments, ignoring them.")
    }
  }
  
  if (!(type %in% c("None", "constantMeanReturn")) && is.null(model.args)) {
    stop("model.args cannot be NULL when 'type' is not 'None' or 'constantMeanReturn'.")
  }
  
  if (is.levels == TRUE) {
    firm.returns <- diff(log(firm.returns)) * 100
  }
  
  ## handle single series
  if (is.null(ncol(firm.returns))) {
    stop("firm.returns should be a zoo series with at least one column. Use '[' with 'drop = FALSE'.")
  }
  
  stopifnot(!is.null(remap))
  
  ## compute estimation and event period
  ## event period starts from event time + 1
  event.period <- as.character((-event.window + 1):event.window)

### Run models
  ## AMM
  if (type == "lmAMM") {
    
    if (length(dim(model.args$market.returns)) == 2) {
      colnames(model.args$market.returns) <- "market.returns" # needed to fix market returns colname
    }
    returns.zoo <- prepare.returns(event.list = event.list,
                                   event.window = event.window,
                                   list(firm.returns = firm.returns,
                                        market.returns = model.args$market.returns,
                                        others = model.args$others))

    outcomes <- do.call(c, sapply(returns.zoo, '[', "outcomes"))
    names(outcomes) <- gsub(".outcomes", "", names(outcomes))
    
    if (all(unique(outcomes) != "success")) {
      message("Error: no successful events")
      to.remap = FALSE
      inference = FALSE
      outputModel <- NULL
    } else {
      returns.zoo <- returns.zoo[which(outcomes == "success")]
      outputModel <- lapply(returns.zoo, function(firm) {
        if (is.null(firm$z.e)) {
          return(NULL)
        }
        estimation.period <- attributes(firm)[["estimation.period"]]
        
        ## Estimating AMM regressors
        args.makeX <- list()
        if (!is.null(model.args$nlag.makeX)) {
          args.makeX$nlags <- model.args$nlag.makeX
        }
        names.args.makeX <- names(model.args)[names(model.args) %in% formalArgs(makeX)]
        names.args.makeX <- names.args.makeX[-match("market.returns", names.args.makeX)]
        names.args.makeX <- names.args.makeX[-match("others", names.args.makeX)]
        args.makeX <- append(args.makeX, model.args[names.args.makeX])
        
        names.nonfirmreturns <- colnames(firm$z.e)[!colnames(firm$z.e) %in% c("firm.returns", "market.returns")]
        args.makeX$market.returns <- firm$z.e[estimation.period, "market.returns"]
        args.makeX$others <- firm$z.e[estimation.period, names.nonfirmreturns]
        regressors <- do.call(makeX, args.makeX)

        args.lmAMM <- list()
        if (!is.null(model.args$nlag.lmAMM)) {
            args.lmAMM$nlags <- model.args$nlag.lmAMM
        }
        args.lmAMM <- append(args.lmAMM, model.args[names(model.args) %in% formalArgs(lmAMM)])
        args.lmAMM$firm.returns <- firm$z.e[estimation.period, "firm.returns"]
        args.lmAMM$X <- regressors

        model <- do.call(lmAMM, args.lmAMM)
        if (is.null(model)) {
            return(NULL)
        }

        abnormal.returns <- firm$z.e[event.period, "firm.returns"] - model$coefficients["(Intercept)"] -
            (model$exposures["market.returns"] * firm$z.e[event.period, "market.returns"])

        for (i in 2:length(model$exposures)) { # 2: not market returns
            abnormal.returns <- abnormal.returns - (model$exposures[i] * firm$z.e[event.period, names.nonfirmreturns[i - 1]])
        }

        attr(abnormal.returns, "residuals") <- model$residuals
        return(abnormal.returns)
      })

      ## remove the NULL values
      null.values <- sapply(outputModel, is.null)
      if (length(which(null.values)) > 0) {
        outputModel <- outputModel[names(which(!null.values))]
        outcomes[names(which(null.values))] <- "edatamissing" # estimation data missing
      }
      
      if (length(outputModel) == 0) {
        warning("lmAMM() returned NULL\n")
        outputModel <- NULL
      } else {
        outputResiduals <- lapply(outputModel, function(x) attributes(x)[["residuals"]])
        outputResiduals <- lapply(outputResiduals, function(x)
                                  zoo(as.numeric(x), order.by = as.integer(names(x))))
        outputModel <- do.call(merge.zoo, outputModel)
      }
    }
  } ## end AMM
  
### marketModel
  if (type == "marketModel") {
    if (length(dim(model.args$market.returns)) == 2) {
      colnames(model.args$market.returns) <- "market.returns" # needed to fix market returns colname
    }
    returns.zoo <- prepare.returns(event.list = event.list,
                                   event.window = event.window,
                                   list(firm.returns = firm.returns,
                                        market.returns = model.args$market.returns))
    
    outcomes <- do.call(c, sapply(returns.zoo, '[', "outcomes"))
    names(outcomes) <- gsub(".outcomes", "", names(outcomes))
    
    if (all(unique(outcomes) != "success")) {
      message("Error: no successful events")
      to.remap = FALSE
      inference = FALSE
      outputModel <- NULL
    } else {
      returns.zoo <- returns.zoo[which(outcomes == "success")]
      outputModel <- lapply(returns.zoo, function(firm) {
        if (is.null(firm$z.e)) {
          return(NULL)
        }
        estimation.period <- attributes(firm)[["estimation.period"]]
        model <- marketModel(firm$z.e[estimation.period, "firm.returns"],
                             firm$z.e[estimation.period, "market.returns"],
                             residuals = FALSE)

        abnormal.returns <- firm$z.e[event.period, "firm.returns"] - model$coefficients["(Intercept)"] -
          (model$coefficients["market.returns"] * firm$z.e[event.period, "market.returns"])
        
        attr(abnormal.returns, "residuals") <- model$residuals
        return(abnormal.returns)
      })
      
      null.values <- sapply(outputModel, is.null)
      if (length(which(null.values)) > 0) {
        outputModel <- outputModel[names(which(!null.values))]
        outcomes[names(which(null.values))] <- "edatamissing"
      }

      if (length(outputModel) == 0) {
        warning("marketModel() returned NULL")
        outputModel <- NULL
      } else {
        outputResiduals <- lapply(outputModel, function(x) attributes(x)[["residuals"]])
        outputResiduals <- lapply(outputResiduals, function(x)
                                  zoo(as.numeric(x), order.by = as.integer(names(x))))
        outputModel <- do.call(merge.zoo, outputModel)
      }
    }
    
  } ## END marketModel


### excessReturn
  if (type == "excessReturn") {
      if (length(dim(model.args$market.returns)) == 2) {
          colnames(model.args$market.returns) <- "market.returns" # needed to fix market returns colname
      }
      returns.zoo <- prepare.returns(event.list = event.list,
                                     event.window = event.window,
                                     list(firm.returns = firm.returns,
                                          market.returns = model.args$market.returns))
      
      outcomes <- do.call(c, sapply(returns.zoo, '[', "outcomes"))
      names(outcomes) <- gsub(".outcomes", "", names(outcomes))
      
      if (all(unique(outcomes) != "success")) {
          message("No successful events")
          to.remap = FALSE
          inference = FALSE
          outputModel <- NULL
      } else {
          returns.zoo <- returns.zoo[which(outcomes == "success")]
          outputModel <- lapply(returns.zoo, function(firm) {
                                    if (is.null(firm$z.e)) {
                                        return(NULL)
                                    }
           estimation.period <- attributes(firm)[["estimation.period"]]
           model <- excessReturn(firm$z.e[c(estimation.period,
                                            event.period),
                                          "firm.returns"],
                                 firm$z.e[c(estimation.period,
                                            event.period),
                                          "market.returns"])
                                    
           abnormal.returns <- model[event.period, ]
           attr(abnormal.returns, "residuals") <- model[estimation.period, ]
           return(abnormal.returns)
                                })
          
          null.values <- sapply(outputModel, is.null)
          if (length(which(null.values)) > 0) {
              outputModel <- outputModel[names(which(!null.values))]
              outcomes[names(which(null.values))] <- "edatamissing"
          }
          
          if (length(outputModel) == 0) {
              warning("excessReturn() returned NULL\n")
              outputModel <- NULL
          } else {
              outputResiduals <- lapply(outputModel, function(x) attributes(x)[["residuals"]])
              outputModel <- do.call(merge.zoo, outputModel[!sapply(outputModel, is.null)])
          }
      }
  } ## end excessReturn


### constantMeanReturn
  if (type == "constantMeanReturn") {
      returns.zoo <- prepare.returns(event.list = event.list,
                                     event.window = event.window,
                                     list(firm.returns = firm.returns))
      outcomes <- do.call(c, sapply(returns.zoo, '[', "outcomes"))
      names(outcomes) <- gsub(".outcomes", "", names(outcomes))
      if (all(unique(outcomes) != "success")) {
          message("Error: no successful events")
          to.remap = FALSE
          inference = FALSE
          outputModel <- NULL
      }  else {
          returns.zoo <- returns.zoo[which(outcomes == "success")]
          outputModel <- lapply(returns.zoo, function(firm) {
                                    if (is.null(firm$z.e)) {
                                        return(NULL)
                                    }
          estimation.period <- as.numeric(attributes(firm)[["estimation.period"]])
          model <- constantMeanReturn(firm$z.e[which(index(firm$z.e) %in% estimation.period), ])
          abnormal.returns <- firm$z.e[which(index(firm$z.e) %in% event.period), ] - model
          attr(abnormal.returns, "residuals") <- firm$z.e[which(index(firm$z.e) %in% estimation.period), ] - model
          return(abnormal.returns)
                                })

          null.values <- sapply(outputModel, is.null)
          if (length(which(null.values)) > 0) {
              outputModel <- outputModel[names(which(!null.values))]
              outcomes[names(which(null.values))] <- "edatamissing"
          }

          if (length(outputModel) == 0) {
              warning("constantMeanReturn() returned NULL\n")
              outputModel <- NULL
          } else {
              outputResiduals <- lapply(outputModel, function(x) attributes(x)[["residuals"]])
              outputModel <- do.call(merge.zoo, outputModel[!sapply(outputModel, is.null)])
          }
      }
  } ## end constantMeanReturn

### None
  if (type == "None") {
    returns.zoo <- prepare.returns(event.list = event.list,
                                   event.window = event.window,
                                   list(firm.returns = firm.returns))
    outcomes <- do.call(c, sapply(returns.zoo, '[', "outcomes"))
    names(outcomes) <- gsub(".outcomes", "", names(outcomes))
    if (all(unique(outcomes) != "success")) {
      message("Error: no successful events")
      to.remap = FALSE
      inference = FALSE
      outputModel <- NULL
    } else {
        returns.zoo <- returns.zoo[which(outcomes == "success")]
        outputModel <- lapply(returns.zoo, function(firm) {
                                  if (is.null(firm$z.e)) {
                                      return(NULL)
                                  }
        estimation.period <- attributes(firm)[["estimation.period"]]
        abnormal.returns <- firm$z.e[event.period]
        return(abnormal.returns)
                              })
        null.values <- sapply(outputModel, is.null)
          if (length(which(null.values)) > 0) {
              outputModel <- outputModel[names(which(!null.values))]
              outcomes[names(which(null.values))] <- "edatamissing"
          }

          if (length(outputModel) == 0) {
              warning("None() returned NULL\n")
              outputModel <- NULL
          } else {
              outputModel <- do.call(merge.zoo,
                                     outputModel[!sapply(outputModel,
                                                         is.null)])
          }
    }
} ## end None


  if (is.null(outputModel)) {
    final.result <- list(result = NULL,
                         outcomes = as.character(outcomes))
    class(final.result) <- "es"
    return(final.result)
  } else if (NCOL(outputModel) == 1) {
    event.number <- which(outcomes == "success")
    message("Only one successful event: #", event.number)
      attr(outputModel, which = "dim") <- c(length(outputModel) , 1)
    attr(outputModel, which = "dimnames") <- list(NULL, event.number)
    if (inference == TRUE) {
      warning("No inference strategy for single successful event.","\n")
      inference <- FALSE
    }
  }
  

### Remapping event frame
  if (to.remap == TRUE) {
    outputModel <- switch(remap,
                          cumsum = remap.cumsum(outputModel,
                            is.pc = FALSE, base = 0),
                          cumprod = remap.cumprod(outputModel,
                            is.pc = TRUE,
                            is.returns = TRUE, base = 100),
                          reindex = remap.event.reindex(outputModel)
                          )
    car <- outputModel
    if(inference == FALSE){
      if(NCOL(outputModel) != 1){
        outputModel <- rowMeans(outputModel)
      } else {
        mean(outputModel)
      }
    }
    remapping <- remap
  } else {
    remapping <- "none"
  }
  
### Inference: confidence intervals
  if (inference == TRUE) {
    ## Bootstrap
    if(inference.strategy == "bootstrap"){
      outputModel <- inference.bootstrap(es.w = outputModel,
                                         to.plot = FALSE)
    }

    ## Classic
    if(inference.strategy == "classic"){
      outputModel <- inference.classic(es.w = outputModel,
                                       to.plot = FALSE)
    }

    ## Wilcox
    if(inference.strategy == "wilcox"){
      outputModel <- inference.wilcox(es.w = outputModel,
                                      to.plot = FALSE)
    }
  }

  final.result <- list(result = outputModel,
                       outcomes = as.character(outcomes))

  if (exists("outputResiduals", mode = "numeric", inherits = FALSE)) {
    attr(final.result, which = "model.residuals") <- outputResiduals
  }

  if (exists("car", mode = "numeric", inherits = FALSE)) {
    attr(final.result, which = "CAR") <- car
  }
  attr(final.result, which = "event.window") <- event.window
  attr(final.result, which = "inference") <- inference
  if (inference == TRUE) {
    attr(final.result, which = "inference.strategy") <- inference.strategy
  }
  attr(final.result, which = "remap") <- remapping
  
  class(final.result) <- "es"
  return(final.result)
}

## return values:
## 2. firm.returns.eventtime: data.frame
## 3. outcomes: vector
## 4. estimation.period: vector
prepare.returns <- function(event.list, event.window, ...) {
    returns <- unlist(list(...), recursive = FALSE)
    other.returns.names <- names(returns)[-match("firm.returns", names(returns))]
    
    if (length(other.returns.names) != 0) { # check for type = "None"
                                        # and "constantMeanReturn"
        returns.zoo <- lapply(1:nrow(event.list), function(i) {
                                  firm.name <- event.list[i, "name"]
                                        # to pick out the common dates
                                        # of data. can't work on event
                                        # time if the dates of data do
                                        # not match before converting
                                        # to event time.
                                        # all = FALSE: pick up dates
                                        # for which data is available
                                        # for all types of returns
        firm.merged <- do.call("merge.zoo",
               c(list(firm.returns = returns$firm.returns[, firm.name]),
                 returns[other.returns.names],
                 all = FALSE, fill = NA))
      ## other.returns.names needs re-assignment here, since "returns"
      ## may have a data.frame as one of the elements, as in case of
      ## lmAMM.
     other.returns.names <- colnames(firm.merged)[-match("firm.returns",
                                              colnames(firm.merged))]

    firm.returns.eventtime <- phys2eventtime(z = firm.merged,
    events = rbind(
    data.frame(name = "firm.returns", when = event.list[i, "when"],
    stringsAsFactors = FALSE),
    data.frame(name = other.returns.names, when = event.list[i, "when"],
    stringsAsFactors = FALSE)),
    width = event.window)
      
      if (any(firm.returns.eventtime$outcomes == "unitmissing")) {
          ## :DOC: there could be NAs in firm and other returns in the merged object
          return(list(z.e = NULL, outcomes = "unitmissing")) # phys2eventtime output object
    }
      
      if (any(firm.returns.eventtime$outcomes == "wdatamissing")) {
          return(list(z.e = NULL, outcomes = "wdatamissing")) # phys2eventtime output object
    }
      
      if (any(firm.returns.eventtime$outcomes == "wrongspan")) {
          ## :DOC: there could be NAs in firm and other returns in the merged object
          return(list(z.e = NULL, outcomes = "wrongspan")) # phys2eventtime output object
    }
      
     firm.returns.eventtime$outcomes <- "success" # keep one value
      
     colnames(firm.returns.eventtime$z.e) <- c("firm.returns", other.returns.names)
      ## :DOC: estimation period goes till event time (inclusive)
      attr(firm.returns.eventtime, which = "estimation.period") <-
        as.character(index(firm.returns.eventtime$z.e)[1]:(-event.window))
      
      return(firm.returns.eventtime)
  })
        names(returns.zoo) <- 1:nrow(event.list)
    
    } else {

      returns.zoo <- lapply(1:nrow(event.list),  function(i) {
     firm.returns.eventtime <- phys2eventtime(z = returns$firm.returns,
                                              events = event.list[i, ],
                                               width = event.window)
      if (any(firm.returns.eventtime$outcomes == "unitmissing")) {
          return(list(z.e = NULL, outcomes = "unitmissing"))
    }

      if (any(firm.returns.eventtime$outcomes == "wdatamissing")) {
          return(list(z.e = NULL, outcomes = "wdatamissing"))
    }

      if (any(firm.returns.eventtime$outcomes == "wrongspan")) {
        return(list(z.e = NULL, outcomes = "wrongspan"))
    }
      firm.returns.eventtime$outcomes <- "success" 
      attr(firm.returns.eventtime, which = "estimation.period") <-
          as.character(index(firm.returns.eventtime$z.e)[1]:(-event.window))
      return(firm.returns.eventtime)
  })
      names(returns.zoo) <- 1:nrow(event.list)
  }
    return(returns.zoo)
}


#########################
## Functions for class es
#########################

print.es <- function(x, ...){
  message("Event study", colnames(x$result)[2], "response with",
      attr(x, "inference"), "inference for CI:")
  print(x$result)
  message("\n","Event outcome has",length(which(x$outcomes=="success")),
      "successful outcomes out of", length(x$outcomes),"events:")
  print(x$outcomes)
}

summary.es <- function(object, ...){
    print.es(object, ...)
}

## XXX: needs fixing for non-inference objects
plot.es <- function(x, ...){
                                        # Defining ylab for
                                        # cumulative sum/ cumulative
                                        # product
  if (attr(x, "remap") == "cumsum") {
    remapLabel <- "Cum."
  } else if (attr(x, "remap") == "cumprod") {
    remapLabel <- "Cum. product"
  } else if (attr(x, "remap") == "reindex") {
    remapLabel <- "Re-index"
  } else {
    remapLabel <- ""
  }
  ylab <- paste0("(", remapLabel, ")",
                 " change in response series (%)")

  if (attributes(x)$inference) {
    if (NCOL(x$result) < 3) {
      message("Error: No confidence bands available to plot.")
      return(invisible(NULL))
    } else {
      plot.inference(x$result, xlab = "Event time", ylab = ylab,
                     main = "", col = "blue")
    }
  } else {
    big <- max(abs(x$result[is.finite(x$result)]))
    hilo <- c(-big, big)
    plot.simple(x$result, xlab = "Event time", ylab = ylab,
                main = "", col = "blue", ylim = hilo)
  }
}

