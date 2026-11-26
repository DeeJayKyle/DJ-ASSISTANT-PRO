import '../core/catalogue.dart';

/// Is an online analyser switched on (Analysis → Analyse, or Settings)?
bool serviceEnabled(Catalogue cat, String svc) =>
    cat.getSetting('svc_$svc') == '1';
