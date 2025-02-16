#' Make hex map
#'
#' @description Main function. Calls `make_hex_grid` and `place_districts` internally.
#'
#' @param state Character for state
#' @param d_2020 Dataframe with district labels. Must be a sf shapefile
#' @param d_usa State borders. See example
#'
#' @examples
#' library(tidyverse)
#'
#' ## shapefile with 435 rows, one for each CD
#' cd_shp <- read_rds("data-out/districts_2020_alarm.rds") |>
#'     filter(!state %in% c("AK", "HI"))
#'
#' st_shp <- cd_shp |>
#'     summarize(geometry = sf::st_union(geometry), .by = state)
#'
#' ## New Hampshire example
#' out <- make_hex_map(cd_shp, state = "NH", d_usa = st_shp)
#'
#' ## Visualize
#' ggplot(out) + geom_sf() + theme_void()
#' @export
make_hex_map = function(state, d_2020, d_usa,
                        hex_per_district=5,
                        iters=25L,
                        assign = TRUE) {

    d_state = dplyr::filter(d_2020, .data$state == .env$state) |>
        sf::st_drop_geometry() |>
        dplyr::rename(district = cd_2020)

    shp = d_2020$geometry[d_2020$state == state]
    outline = d_usa$geometry[d_usa$state == state]

    cli::cli_h1(paste("Making map for", state))

    cli::cli_process_start("Making hexagonal grid")
    res = make_hex_grid(shp, outline, hex_per_district=hex_per_district)
    cli::cli_process_done()

    if (assign) {
        cli::cli_process_start("Assigning districts to grid")
        res <- place_districts(res, n_runs = iters) |>
            dplyr::mutate(state = state, .before=.data$district)
        cli::cli_process_done()
        return(res)
    } else {
        return(res)
    }
}


#' Partitions state geometry into hexagonal units based on CD geometries
#'
#' @details Usually called by `make_hex_map`
#'
#'  @examples
#' # New Hampshire in 2005
#' \dontrun{
#' library(tidyverse)
#' library(geomander)
#'
#' cd_geom <- geomander::get_lewis(state = "NH", congress = 109) |>
#'     mutate(state = "NH", .before = 1) |>
#'     st_make_valid() |>
#'     pull(geometry)
#'
#' st_geom <- summarize(cd_use, geometry = st_union(geometry), .by = state) |>
#'     pull(geometry)
#'
#' out <- make_hex_grid(shp = cd_geom, outline = st_geom)
#'
#' # Show output
#' ggplot(out$hex) +
#'     geom_sf() +
#'     geom_point(data = out$distr, aes(x = X, y = Y))
#' }
#' @export
make_hex_grid = function(shp, outline, hex_per_district=5, infl=1.05) {
    shp = sf::st_transform(shp, 3857)
    outline = sf::st_transform(outline, 3857)

    # recenter shp to outline
    shp = shp - sf::st_centroid(sf::st_union(shp)) + sf::st_centroid(outline)
    sf::st_crs(outline) = 3857
    sf::st_crs(shp) = 3857

    bbox = sf::st_bbox(shp)
    shp_area = as.numeric(sum(sf::st_area(sf::st_buffer(shp, 5e3))))
    bbox_area = diff(bbox[c(2, 4)]) * diff(bbox[c(1, 3)])
    shp_frac = min(shp_area / bbox_area, 1)

    a_ratio = diff(bbox[c(2, 4)]) / diff(bbox[c(1, 3)])
    n_hex = round(length(shp) * hex_per_district * infl)

    # initialize hex grid and intersect with outline
    hex = data.frame()
    cuml_infl = 0.75
    base_area = NULL
    while (nrow(hex) <= n_hex) {
        n_dim = floor(sqrt(cuml_infl * n_hex * c(1/a_ratio, a_ratio)))

        hex = sf::st_make_grid(outline, n=n_dim, square=FALSE, flat_topped=TRUE)
        hex = sf::st_filter(sf::st_sf(geometry=hex), outline)
        base_area = median(as.numeric(sf::st_area(hex)))
        hex = sf::st_intersection(hex, outline) |>
            dplyr::filter(as.numeric(sf::st_area(.data$geometry)) / base_area >= 0.25)
        stopifnot(nrow(hex) > 0)

        cuml_infl = cuml_infl * 1.1
    }


    hex = hex |>
        sf::st_centroid() |>
        sf::st_union() |>
        sf::st_voronoi(outline) |>
        sf::st_collection_extract(type="POLYGON") |>
        sf::st_intersection(outline) |>
        sf::st_sf(geometry=_) |>
        sf::st_transform(5070)
    hex$adj = geomander::adjacency(hex)

    connect = geomander::suggest_component_connection(hex, hex$adj)
    for (i in seq_len(nrow(connect))) {
        hex$adj = geomander::add_edge(hex$adj, connect$x[i], connect$y[i])
    }

    shp_adj = sf::st_buffer(shp, 2e3) |>
        sf::st_sf(geometry=_) |>
        geomander::adjacency()

    shp_out = sf::st_transform(shp, 5070) |>
        sf::st_centroid() |>
        sf::st_coordinates() |>
        dplyr::as_tibble() |>
        dplyr::mutate(adj = shp_adj)

    # hexagon size
    base_size = round(sf::st_area(hex) / 3e8) |>
        table() |>
        which.max() |>
        names() |>
        as.numeric()

    list(n_distr=length(shp),
         n_hex=n_hex,
         base_size=base_size,
         hex=hex,
         distr=shp_out)
}


#' Uses the Hungarian algorithm to group (hex) units into `n_distr` groups
#' @param res Output of `make_hex_grid`
place_districts = function(res, n_runs=50L,
                           max_bursts=300 + round(sqrt(res$n_distr)*25),
                           silent=FALSE) {
    if (res$n_distr == 1) {
        out = res$hex |>
            dplyr::mutate(district = 1) |>
            dplyr::summarize(.by = district)
        return(out)
    }

    map = redist::redist_map(res$hex, pop=1, ndists=res$n_distr,
                             pop_tol=1.3 * res$n_distr^1.075 / nrow(res$hex),
                             adj=res$hex$adj)

    sc_close = scorer_close(res)
    scorer = redist::scorer_frac_kept(map) + 2*sc_close

    if (!silent) cli::cli_process_start("Initializing districts")
    inits = redist::redist_smc(map, max(round(3 * sqrt(n_runs*res$n_distr)), n_runs),
                               resample=FALSE, pop_temper=0.005, seq_alpha=0.95,
                               ncores=1, silent=TRUE) |>
        as.matrix()
    if (!silent) cli::cli_process_done()

    if (!silent)
    looper = seq_len(n_runs)
    if (!silent) looper = cli::cli_progress_along(looper, "Optimizing", clear=FALSE)
    opt = do.call(rbind, lapply(looper, function(i) {
        redist::redist_shortburst(map, scorer, init_plan=inits[, i],
                                  burst_size=round(2 * sqrt(res$n_distr)),
                                  max_bursts=max_bursts, return_all=FALSE, verbose=FALSE)
    })) |>
        dplyr::filter(score == max(.data$score))
    if (!silent) cli::cli_progress_done()

    pl = redist::last_plan(opt)
    matcher = attr(sc_close, "hungarian")(pl)
    pl = matcher$pairs[pl, 2]

    out = res$hex |>
        dplyr::group_by(district = pl) |>
        dplyr::summarize()
    out$geom_label = geomander::st_circle_center(out)$geometry

    out
}


#' Hungarian algorithm
#' @param res Called from `place_districts`
#' @importFrom RcppHungarian HungarianSolver
scorer_close = function(res) {
    m_coord_hex = sf::st_centroid(res$hex$geometry) |>
        sf::st_coordinates() |>
        dplyr::as_tibble()
    m_coord_shp = as.matrix(res$distr[, 1:2])
    areas = as.numeric(sf::st_area(res$hex$geometry))
    areas = areas / sum(areas)
    idx1 = seq_len(res$n_distr)
    idx2 = seq_len(res$n_distr) + res$n_distr
    tot_links = lengths(res$distr$adj)

    fn_hungarian = function(pl) {
        center_x = tapply(m_coord_hex$X, pl, mean)
        center_y = tapply(m_coord_hex$Y, pl, mean)
        m_coords = 1e-6 * rbind(cbind(center_x, center_y), m_coord_shp)
        m_dist = as.matrix(dist(m_coords))[idx1, idx2]
        RcppHungarian::HungarianSolver(m_dist^2)
    }

    fn <- function(plans) {
        apply(plans, 2, function(pl) {
            matcher = fn_hungarian(pl)
            distr_adj = redist:::coarsen_adjacency(res$hex$adj, matcher$pairs[pl, 2] - 1L)
            shared_links = sapply(seq_len(res$n_distr), function(i) {
                length(intersect(distr_adj[[i]], res$distr$adj[[i]]))
            })
            mean(shared_links / tot_links) - 6*matcher$cost/res$n_distr - 12*sd(tapply(areas, pl, sum))
        })
    }

    class(fn) <- c("redist_scorer", "function")
    attr(fn, "hungarian") = fn_hungarian
    fn
}
