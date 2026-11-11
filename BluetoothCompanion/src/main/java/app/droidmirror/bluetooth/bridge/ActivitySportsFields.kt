package app.droidmirror.bluetooth.bridge

/** Public source resource names identify ESPN teams even when logos share a row with scores. */
internal object ActivitySportsFields {
    fun team(name: String, inherited: Int): Int {
        val id = name.lowercase(java.util.Locale.ROOT)
        val turn = indicator(name, "") != null
        return when {
            turn && (id.contains("home") || Regex("(?:possession|serving|batting|server)_(?:one|1)(?:_|$)").containsMatchIn(id)) -> 1
            turn && (id.contains("away") || Regex("(?:possession|serving|batting|server)_(?:two|2)(?:_|$)").containsMatchIn(id)) -> 2
            listOf("team_one", "home_team", "team1", "home_score", "score_one").any(id::contains) -> 1
            listOf("team_two", "away_team", "team2", "away_score", "score_two").any(id::contains) -> 2
            else -> inherited
        }
    }
    /** Only explicit source markers; field position/down-and-distance never proves possession. */
    fun indicator(name: String, description: String): String? {
        val id = name.lowercase(java.util.Locale.ROOT)
        val label = description.trim().lowercase(java.util.Locale.ROOT)
        if (Regex("winner|victory|favorite").containsMatchIn("$id $label") ||
            Regex("[0-9]+\\s*(?:%|percent)|[0-9]+:[0-9]+").containsMatchIn(label)) return null
        if (listOf("time_of_possession", "possession_time", "possession_percent", "possession_stat",
                   "serving_percent", "serving_stat", "batting_average").any(id::contains)) return null
        return when {
            id.contains("possession") || id.contains("has_ball") || label.contains("has the ball") || label.contains("possession") ||
                label in listOf("possession", "has ball", "has the ball", "in possession") -> "possession"
            Regex("serving|server|(?:^|_)serve(?:$|_)").containsMatchIn(id) ||
                Regex("serving|server|(?:^|[_\\s])serve(?:$|[_\\s])").containsMatchIn(label) -> "serving"
            id.contains("batting") || id.contains("at_bat") ||
                Regex("(?:^|_)(?:batting|at_bat)_(?:one|two|home|away|1|2)(?:_|$)").containsMatchIn(id) ||
                label.contains("batting") || label.contains("at bat") -> "batting"
            else -> null
        }
    }
    fun gameClock(name: String): Boolean {
        val id = name.lowercase(java.util.Locale.ROOT)
        if (listOf("shot", "play_clock", "playclock", "timeout", "countdown_to", "pregame").any(id::contains)) return false
        return listOf("game_clock", "game_timer", "period_clock", "match_clock", "status_primary").any(id::contains) || id == "game_status"
    }
    fun setScore(name: String): Boolean = Regex("(?:^|_)set(?:s|_\\d+)?_(?:score|scores)(?:_|$)|(?:^|_)score_set(?:_|$)",
        RegexOption.IGNORE_CASE).containsMatchIn(name)
    fun field(name: String, image: Boolean, text: Boolean): String? {
        val id = name.lowercase(java.util.Locale.ROOT)
        return when {
            image && id in listOf("iv_bases", "base_occupancy") -> "bases"
            text && setScore(id) -> "setScore"
            text && id in listOf("tv_network_chip", "tv_pre_broadcast_overflow") -> "broadcast"
            text && (id.contains("game_status") || id.contains("status_primary") || id == "tv_pre_status_line_one") -> "statusPrimary"
            text && id.contains("status_secondary") -> "statusSecondary"
            image && !id.contains("indicator") && listOf("logo", "iv_team", "team_icon").any(id::contains) -> "logo"
            text && id.contains("score") -> "score"
            text && id.contains("name") -> "name"
            else -> null
        }
    }
}
